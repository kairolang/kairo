/// --- The Kairo Project ---------------------- Analyzer/Server/Output.k --- ///
///
///   What the server says: responses, notifications, requests, log and trace lines, progress.
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
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Protocol::*
import Server::ClangdBridge::*
import Server::CodeActions::*
import Server::Completion::*
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
import Server::Lifecycle::*
import Server::Lookup::*
import Server::Navigation::*
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*
import Support::FileIO::Path::Path
import TextScan::{
    InterfacePlan,
    Span,
    call_at,
    interface_for,
    spans,
}
import Tuning::*
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io

extend Server {
    /// A line for the person using the editor: it goes to the client's log
    /// for this server (`window/logMessage`, the "Kairo" output channel in
    /// VS Code, the language server log in Zed), to stderr, and to the
    /// trace. `level` is LSP's MessageType: 1 error, 2 warning, 3 info, 4 log.
    fn say(self, level: i64, const s: string) {
        io::eprintln("kals: " + s)
        self.trace("log " + s)
        if self.ready() {
            var w = JsonWriter()
            w.begin_object()
            w.field_int(K_TYPE, level)
            w.field(K_MESSAGE, s)
            w.end_object()
            self.notify(M_LOG_MESSAGE, w.out)
        }
    }

    fn log(self, const s: string) {
        self.say(MSG_WARNING, s)
    }

    /// One line per message in and out, kept in memory and written to
    /// `<scratch>/trace.log` whenever the loop goes idle. An editor shows
    /// what it drew, not what it was told; this is the other half, and it is
    /// what a bug report about "the highlighting disappeared" needs.
    fn trace(self, const line: string) {
        self.trace_buf += line
        self.trace_buf += "\n"
        self.trace_dirty = true
        // Bounded: the last few hundred messages are the ones that matter.
        if self.trace_buf.size() > TRACE_CAP_BYTES {
            self.trace_buf = self.trace_buf.subslice(
                self.trace_buf.size() - TRACE_KEEP_BYTES,
                TRACE_KEEP_BYTES,
            )
        }
    }

    fn flush_trace(self) {
        if self.trace_dirty && (!self.tmp.is_empty()) {
            LinkFS::write(Path::join_str(self.tmp, "trace.log"), self.trace_buf)
            self.trace_dirty = false
        }
    }

    fn respond(self, const id: string, const result: string) {
        var w = JsonWriter()
        w.begin_object()
        w.field(K_JSONRPC, JSONRPC_VERSION)
        w.field_raw(K_ID, id)
        w.field_raw(K_RESULT, result)
        w.end_object()
        var head = result.copy()
        if head.size() > 80 {
            head = head.subslice(0, 80)
        }

        self.trace(f"-> {id} {result.size()}B " + head)
        self.t.send(w.out)
    }

    fn respond_error(self, const id: string, code: i64, const message: string) {
        var w = JsonWriter()
        w.begin_object()
        w.field(K_JSONRPC, JSONRPC_VERSION)
        w.field_raw(K_ID, id)
        w.key(K_ERROR)
        w.begin_object()
        w.field_int(K_CODE, code)
        w.field(K_MESSAGE, message)
        w.end_object()
        w.end_object()
        self.trace(f"-> {id} ERROR {code} " + message)
        self.t.send(w.out)
    }

    fn notify(self, const method: string, const params: string) {
        self.trace(f"-> notify {method} {params.size()}B")
        var w = JsonWriter()
        w.begin_object()
        w.field(K_JSONRPC, JSONRPC_VERSION)
        w.field(K_METHOD, method)
        w.field_raw(K_PARAMS, params)
        w.end_object()
        self.t.send(w.out)
    }

    /// A request of our own; the editor's reply carries no method and is
    /// dropped in handle().
    fn request(self, const method: string) {
        self.seq += 1
        var w = JsonWriter()
        w.begin_object()
        w.field(K_JSONRPC, JSONRPC_VERSION)
        w.field(K_ID, f"kals-{self.seq}")
        w.field(K_METHOD, method)
        w.end_object()
        self.t.send(w.out)
    }

    /// The same, with `params` (JSON). Returns the request's id.
    fn request_with(self, const method: string, const params: string) -> string {
        self.seq += 1
        var id = f"kals-{self.seq}"
        var w  = JsonWriter()
        w.begin_object()
        w.field(K_JSONRPC, JSONRPC_VERSION)
        w.field(K_ID, id)
        w.field(K_METHOD, method)
        w.field_raw(K_PARAMS, params)
        w.end_object()
        self.trace(f"-> request {method}")
        self.t.send(w.out)
        return id
    }

    /// Creates a work-done progress token for an index run and returns it.
    /// Nothing is reported for it before the client answers (see `progress`).
    fn progress_create(self) -> string {
        self.seq += 1
        var pt = ProgressToken()
        pt.token = f"kals-index-{self.seq}"
        var cw = JsonWriter()
        cw.begin_object()
        cw.field(K_TOKEN, pt.token)
        cw.end_object()
        pt.req_id = "\"" + self.request_with(
            M_WORK_DONE_PROGRESS_CREATE,
            cw.out,
        ) + "\""
        var token = pt.token.copy()
        self.ptokens.push(pt)
        return token
    }

    /// Forgets token `i`; the last token takes its place (tokens are found by
    /// name, so their order carries nothing).
    fn drop_ptoken_(self, i: usize) {
        var last = self.ptokens.pop()
        if (i < self.ptokens.size()) && last? {
            self.ptokens[i] = last
        }
    }

    /// The reply to request `id` (JSON text). When it answers a token's
    /// create, what was queued for the token is sent (no error) or dropped
    /// (an error: the client does not want progress for this token).
    fn progress_answered(self, const id: string, ok: bool) {
        for var i: usize = 0; i < self.ptokens.size(); ++i {
            if (self.ptokens[i].state != 0) || (self.ptokens[i].req_id != id) {
                continue
            }

            if !ok {
                self.ptokens[i].state = 2
                self.trace("progress token refused " + self.ptokens[i].token)
                var ended = false
                for var q: usize = 0; q < self.ptokens[i].queued.size(); ++q {
                    if self.ptokens[i].queued[q].kind == "end" {
                        ended = true
                    }
                }

                self.ptokens[i].queued.clear()
                if ended {
                    self.drop_ptoken_(i)
                }

                return
            }

            self.ptokens[i].state = 1
            var token  = self.ptokens[i].token.copy()
            var queued = self.ptokens[i].queued.copy()
            self.ptokens[i].queued.clear()
            for var q: usize = 0; q < queued.size(); ++q {
                self.progress(
                    token,
                    queued[q].kind,
                    queued[q].message,
                    queued[q].pct,
                )
            }

            return
        }
    }

    /// One `$/progress` notification for `token`: `kind` is begin, report
    /// or end; `pct` < 0 leaves the percentage out (indeterminate). A token
    /// whose create is not answered yet holds the notification back (only
    /// the newest report is kept); one the client refused drops it. An end
    /// forgets the token.
    fn progress(self, const token: string, const kind: string, const message: string, pct: i64) {
        var at = usize::MAX
        for var i: usize = 0; i < self.ptokens.size(); ++i {
            if self.ptokens[i].token == token {
                at = i
            }
        }

        if at != usize::MAX {
            if self.ptokens[at].state == 0 {
                var m = ProgressMsg()
                m.kind    = kind.copy()
                m.message = message.copy()
                m.pct     = pct
                var n = self.ptokens[at].queued.size()
                if (kind == "report")
                    && (n > 0)
                    && (self.ptokens[at].queued[n - 1].kind == "report") {
                    self.ptokens[at].queued[n - 1] = m
                } else {
                    self.ptokens[at].queued.push(m)
                }

                return
            }

            var refused = self.ptokens[at].state == 2
            if kind == "end" {
                self.drop_ptoken_(at)
            }

            if refused {
                return
            }
        }

        var w = JsonWriter()
        w.begin_object()
        w.field(K_TOKEN, token)
        w.key(K_VALUE)
        w.begin_object()
        w.field(K_KIND, kind)
        if kind == "begin" {
            w.field(K_TITLE, "Indexing Kairo")
            w.field_bool("cancellable", false)
        }

        if !message.is_empty() {
            w.field(K_MESSAGE, message)
        }

        if (pct >= 0) && (kind != "end") {
            w.field_int("percentage", pct)
        }

        w.end_object()
        w.end_object()
        self.notify(M_PROGRESS, w.out)
    }

    fn show(self, level: i64, const text: string) {
        var w = JsonWriter()
        w.begin_object()
        w.field_int(K_TYPE, level)
        w.field(K_MESSAGE, text)
        w.end_object()
        self.notify(M_SHOW_MESSAGE, w.out)
    }

    // --- paths -----------------------------------------------------------
    //
    // One spelling per file. The compiler names a file by its real path (the
    // worker runs in the project's real directory), while an editor may have
    // reached the workspace through a symlink; every path the server keys on
    // is therefore the real one, and a URI goes back out in the spelling the
    // editor used for that buffer.

    fn path_of(self, const uri: string) -> string {
        var i = self.docs.index_of(uri)
        if i != usize::MAX {
            return self.docs.docs[i].path.copy()
        }

        return Path::real_path_of(uri_to_path(uri))
    }

    fn uri_of(self, const path: string) -> string {
        var i = self.docs.index_of_path(path)
        if i != usize::MAX {
            return self.docs.docs[i].uri.copy()
        }

        return path_to_uri(path)
    }

    /// A sibling tool of the toolchain: beside this binary first (one
    /// install, one version), then on PATH. "" when it is in neither.
    fn tool(self, const name: string) -> string {
        var beside = Path::join_str(Path::parent_of(self.exe), name.copy())
        if Path::exists_at(beside) {
            return beside
        }

        if Path::exists_at(beside.copy() + ".exe") {
            return beside + ".exe"
        }

        var found = llvm::sys::findProgramByName(kairo::sref(name))
        if found.getError().value() != 0 {
            return ""
        }

        return string(
            unsafe ((found.get().c_str() as unsafe *const u8) as *const u8),
        )
    }

    // --- entries ---------------------------------------------------------

    /// Reads each progress-reporting worker's count of checked files and
    /// reports it when it moved: `N/M`, M being the files the entry's last
    /// run read (unknown on a very first run: a count without a percentage).
    fn report_progress(self) {
        for var q: usize = 0; q < self.jobs.size(); ++q {
            if (self.jobs[q].kind != JobKind::Index) || self.jobs[q].progress.is_empty() {
                continue
            }

            var text: string = ""
            if !LinkFS::read(self.jobs[q].prog_file, &text) {
                continue
            }

            var n: i64 = 0
            for var c: usize = 0; c < text.size(); ++c {
                if (text.data()[c] >= ('0' as u8)) && (text.data()[c] <= ('9' as u8)) {
                    n = (n * 10) + ((text.data()[c] - 48) as i64)
                }
            }

            if n == self.jobs[q].prog_n {
                continue
            }

            self.jobs[q].prog_n = n
            var m: i64 = 0
            var pe     = self.entry_by_id(self.jobs[q].entry_id)
            if pe != usize::MAX {
                m = self.entries[pe].files.size() as i64
            }

            if m > 0 {
                var shown = if n > m => m else => n
                var pct   = (shown * 100) / m
                if pct > 99 {
                    pct = 99
                }

                self.progress(
                    self.jobs[q].progress,
                    "report",
                    f"{shown}/{m}",
                    pct,
                )
            } else {
                self.progress(self.jobs[q].progress, "report", f"{n} files", -1)
            }
        }
    }
}
