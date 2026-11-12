/// --- The Kairo Project ----------------- Analyzer/Server/Diagnostics.k --- ///
///
///   Diagnostics: publishing an entry's, and the per-keystroke syntax pass.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "chrono"

import API::FS::LinkFS
import DocumentStore::{
    DocumentStore,
    fnv1a,
    path_to_uri,
    uri_to_path,
}
import Index::Legend::*
import Index::Snapshot::*
import Protocol::*
import Tuning::*
import WorkerArgs::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io
import Server::ClangdBridge::*
import Server::CodeActions::*
import Server::Completion::*
import Server::Features::*
import Server::Formatting::*
import Server::Lifecycle::*
import Server::Lookup::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*

/// True for an LSP Diagnostic code the parser (not Sema) reports: `S<n>`,
/// and not the semantic category `SC<n>`.
pub fn is_syntax_code(const code: string) -> bool {
    return (code.size() > 1) && (code[0] == ('S' as u8)) && (code[1] != ('C' as u8))
}

extend Server {
    /// Sends this entry's diagnostics, one notification per file, and clears
    /// the files that had some last time and have none now.
    fn publish(self, ei: usize) {
        var *s = &self.entries[ei].snap
        var diags = s->get(s->root, SK_DIAGNOSTICS)

        var paths: [string]
        var d = s->first(diags)
        while d != JSON_NONE() {
            var p = s->get_str(d, SK_PATH)
            if p.empty() {
                p = self.entries[ei].entry
            }

            var seen = false
            for var i: usize = 0; i < paths.size(); ++i {
                if paths[i] == p {
                    seen = true
                }
            }

            if !seen {
                paths.push_back(p)
            }

            d = s->next(d)
        }

        // An open buffer whose syntax pass is newer than this run keeps
        // that pass's errors (compose_diags), even where the run reported
        // nothing for it.
        for var k: usize = 0; k < self.docs.docs.size(); ++k {
            var dp = self.docs.docs[k].path
            if ((self.docs.docs[k].syn.landed && (self.docs.docs[k].syn.at > self.entries[ei].snap_rev))
                || self.docs.docs[k].side_current()) && self.entries[ei].holds(dp) {
                var seen = false
                for var q: usize = 0; q < paths.size(); ++q {
                    if paths[q] == dp {
                        seen = true
                    }
                }

                if !seen {
                    paths.push_back(dp)
                }
            }
        }

        var now: [string]
        for var i: usize = 0; i < paths.size(); ++i {
            var uri = self.uri_of(paths[i])
            var n: usize = 0
            var arr = self.compose_diags(ei, paths[i], &n)
            if n == 0 {
                continue
            }

            var w = JsonWriter()
            w.begin_object()
            w.field(K_URI, uri)
            w.field_raw(K_DIAGNOSTICS, arr)
            w.end_object()
            self.notify(M_PUBLISH_DIAGNOSTICS, w.out)
            now.push_back(uri)
        }

        for var i: usize = 0; i < self.entries[ei].published.size(); ++i {
            var still = false
            for var k: usize = 0; k < now.size(); ++k {
                if now[k] == self.entries[ei].published[i] {
                    still = true
                }
            }

            if !still {
                var w = JsonWriter()
                w.begin_object()
                w.field(K_URI, self.entries[ei].published[i])
                w.field_raw(K_DIAGNOSTICS, "[]")
                w.end_object()
                self.notify(M_PUBLISH_DIAGNOSTICS, w.out)
            }
        }

        self.entries[ei].published = now
    }

    // --- snapshot lookups ------------------------------------------------

    /// Starts the syntax-only pass of buffer \p di: its current text, parsed
    /// alone (no imports, no Sema).
    fn start_syntax(self, di: usize) {
        if self.launch_held() {
            return // still due
        }

        self.docs.docs[di].sync()
        var overlay = self.overlay_of_(di)

        var j = Job()
        j.kind       = JobKind::Syntax
        j.path       = self.docs.docs[di].path
        j.out        = self.scratch(".json")
        j.log        = self.scratch(".log")
        j.rev        = self.rev
        j.started_ms = now_ms()

        var argv: [string]
        argv.push_back(self.exe)
        argv.push_back(WA_WORKER)
        argv.push_back(j.out)
        argv.push_back(WA_SYNTAX_ONLY)
        argv.push_back(j.path)
        argv.push_back(WA_OVERLAY)
        argv.push_back(j.path)
        argv.push_back(overlay)
        argv.push_back(WA_END)
        argv.push_back(j.path)

        // The buffer is no longer due only once its pass is running: a
        // refused launch leaves it due, and the loop tries again.
        if self.launch_job(&argv, &j, "syntax") != LaunchResult::Started {
            return
        }

        self.docs.docs[di].syn.begin(self.docs.docs[di].changed_at)
        self.trace(f"syntax start rev={j.rev} " + j.path)
        self.jobs.push_back(j)
    }

    fn finish_syntax(self, j: *Job, rc: i32) {
        var di = self.docs.index_of_path(j->path)
        if di == usize::MAX {
            return // closed meanwhile
        }

        self.docs.docs[di].syn.finish()
        var took = now_ms() - j->started_ms
        self.trace(f"syntax done rc={rc} rev={j->rev} {took} ms " + j->path)

        var text: string = ""
        var doc = JsonDoc()
        if !(LinkFS::read(j->out, &text) && doc.parse(text) && doc.get_bool(doc.root, SK_OK)) {
            return // a crash costs the fast path only; the Sema run still comes
        }

        self.land_syntax(di, j->rev, &doc, true)
    }

    /// Takes a syntax pass's answer \p doc (as syntax_main writes it) for
    /// buffer \p di at server revision \p rev, and publishes it when \p
    /// publish. Either path, a process per pass or the persistent worker,
    /// under the one rule of SyntaxState::land: an answer for a text the
    /// buffer no longer holds is dropped (its positions are the old
    /// text's), and so is one older than what has landed.
    fn land_syntax(self, di: usize, rev: u64, doc: *JsonDoc, publish: bool) {
        if !self.docs.docs[di].syn.accepts(rev, self.docs.docs[di].changed_at) {
            self.trace(f"syntax dropped rev={rev}: the buffer changed since " + self.docs.docs[di].path)
            return
        }

        var diags: string = ""
        var x = doc->first(doc->get(doc->root, SK_DIAGNOSTICS))
        while x != JSON_NONE() {
            if !diags.empty() {
                diags += ","
            }

            diags += doc->dump(doc->get(x, SK_DIAG))
            x = doc->next(x)
        }

        var tokens: [i64]
        var t = doc->first(doc->get(doc->root, SK_TOKENS))
        while t != JSON_NONE() {
            tokens.push_back(doc->as_int(t))
            t = doc->next(t)
        }

        self.docs.docs[di].syn.land(rev, self.docs.docs[di].changed_at, doc->get_bool(doc->root, SK_PARSED), doc->get_bool(doc->root, SK_UNSURE), diags, &tokens)

        if publish {
            self.publish_syntax(di)
        }

        self.retry_parked(false)
    }

    /// The diagnostics to show for \p path, as a JSON array, and their
    /// number in \p n. The newest result wins per buffer: when the buffer's
    /// syntax pass saw a later text than entry \p ei's last run, its errors
    /// replace that run's syntax errors (which are at old positions, or
    /// fixed) and the run's other diagnostics stay until the next run. Sema
    /// results for every OTHER file are the run's alone.
    fn compose_diags(self, ei: usize, const path: string, n: *usize) -> string {
        var out: string = "["
        *n = 0
        var di = self.docs.index_of_path(path)
        // A buffer that does not parse, tried by the live worker without
        // being kept (LiveIndex.k): that check read exactly this text, the
        // parser's errors and what Sema says of the rest of the file, so
        // it is the whole answer. The entry's run is of an older text of it.
        if (di != usize::MAX) && self.docs.docs[di].side_current() {
            *n = self.docs.docs[di].side_n
            return "[" + self.docs.docs[di].side_diags + "]"
        }

        var have_snap = (ei != usize::MAX) && self.entries[ei].has_snap
        var syn_newer = (di != usize::MAX) && self.docs.docs[di].syn.landed
            && ((!have_snap) || (self.docs.docs[di].syn.at > self.entries[ei].snap_rev))
        if syn_newer && (!self.docs.docs[di].syn.diags.empty()) {
            out += self.docs.docs[di].syn.diags
            *n = 1
        }

        if have_snap {
            var *s = &self.entries[ei].snap
            var d = s->first(s->get(s->root, SK_DIAGNOSTICS))
            while d != JSON_NONE() {
                var p = s->get_str(d, SK_PATH)
                if p.empty() {
                    p = self.entries[ei].entry
                }

                var dg = s->get(d, SK_DIAG)
                if (p == path) && ((!syn_newer) || (!is_syntax_code(s->get_str(dg, K_CODE)))) {
                    if *n > 0 {
                        out += ","
                    }

                    out += s->dump(dg)
                    *n += 1
                }

                d = s->next(d)
            }
        }

        out += "]"
        return out
    }

    /// Publishes buffer \p di's diagnostics after its syntax pass, unless
    /// the entry's last run is at least as new (it has published already).
    fn publish_syntax(self, di: usize) {
        var path = self.docs.docs[di].path
        var ei = self.entry_of(path)
        if (ei != usize::MAX) && self.entries[ei].has_snap && (self.entries[ei].snap_rev >= self.docs.docs[di].syn.at) {
            return
        }

        var n: usize = 0
        var arr = self.compose_diags(ei, path, &n)
        var w = JsonWriter()
        w.begin_object()
        w.field(K_URI, self.docs.docs[di].uri)
        w.field_raw(K_DIAGNOSTICS, arr)
        w.end_object()
        self.notify(M_PUBLISH_DIAGNOSTICS, w.out)

        if ei == usize::MAX {
            return
        }

        var uri = self.docs.docs[di].uri
        var kept: [string]
        for var k: usize = 0; k < self.entries[ei].published.size(); ++k {
            if self.entries[ei].published[k] != uri {
                kept.push_back(self.entries[ei].published[k])
            }
        }

        if n > 0 {
            kept.push_back(uri)
        }

        self.entries[ei].published = kept
    }

    /// Publishes buffer \p di's diagnostics as they now compose (a live
    /// worker's aside result landed for it), and keeps entry \p ei's list
    /// of files that show some.
    fn publish_doc(self, ei: usize, di: usize) {
        var n: usize = 0
        var arr = self.compose_diags(ei, self.docs.docs[di].path, &n)
        var w = JsonWriter()
        w.begin_object()
        w.field(K_URI, self.docs.docs[di].uri)
        w.field_raw(K_DIAGNOSTICS, arr)
        w.end_object()
        self.notify(M_PUBLISH_DIAGNOSTICS, w.out)

        var uri = self.docs.docs[di].uri
        var kept: [string]
        for var k: usize = 0; k < self.entries[ei].published.size(); ++k {
            if self.entries[ei].published[k] != uri {
                kept.push_back(self.entries[ei].published[k])
            }
        }

        if n > 0 {
            kept.push_back(uri)
        }

        self.entries[ei].published = kept
    }

    // --- parking ---------------------------------------------------------
}
