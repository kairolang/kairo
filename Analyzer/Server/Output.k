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
import Protocol::*
import Tuning::*
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

extend Server {
    /// A line for the person using the editor: it goes to the client's log
    /// for this server (`window/logMessage`, the "Kairo" output channel in
    /// VS Code, the language server log in Zed), to stderr, and to the
    /// trace. \p level is LSP's MessageType: 1 error, 2 warning, 3 info, 4 log.
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
            self.trace_buf = self.trace_buf.subslice(self.trace_buf.size() - TRACE_KEEP_BYTES, TRACE_KEEP_BYTES)
        }
    }

    fn flush_trace(self) {
        if self.trace_dirty && (!self.tmp.empty()) {
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
        var head = result
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

    /// The same, with \p params (JSON).
    fn request_with(self, const method: string, const params: string) {
        self.seq += 1
        var w = JsonWriter()
        w.begin_object()
        w.field(K_JSONRPC, JSONRPC_VERSION)
        w.field(K_ID, f"kals-{self.seq}")
        w.field(K_METHOD, method)
        w.field_raw(K_PARAMS, params)
        w.end_object()
        self.trace(f"-> request {method}")
        self.t.send(w.out)
    }

    /// One `$/progress` notification for \p token: \p kind is begin, report
    /// or end; \p pct < 0 leaves the percentage out (indeterminate).
    fn progress(self, const token: string, const kind: string, const message: string, pct: i64) {
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

        if !message.empty() {
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
            return self.docs.docs[i].path
        }

        return Path::real_path_of(uri_to_path(uri))
    }

    fn uri_of(self, const path: string) -> string {
        var i = self.docs.index_of_path(path)
        if i != usize::MAX {
            return self.docs.docs[i].uri
        }

        return path_to_uri(path)
    }

    /// A sibling tool of the toolchain: beside this binary first (one
    /// install, one version), then on PATH. "" when it is in neither.
    fn tool(self, const name: string) -> string {
        var beside = Path::join_str(Path::parent_of(self.exe), name)
        if Path::exists_at(beside) {
            return beside
        }

        if Path::exists_at(beside + ".exe") {
            return beside + ".exe"
        }

        var found = llvm::sys::findProgramByName(kairo::sref(name))
        if found.getError().value() != 0 {
            return ""
        }

        return string(unsafe ((found.get().c_str() as unsafe *const u8) as *const u8))
    }

    // --- entries ---------------------------------------------------------

    /// Reads each progress-reporting worker's count of checked files and
    /// reports it when it moved: `N/M`, M being the files the entry's last
    /// run read (unknown on a very first run: a count without a percentage).
    fn report_progress(self) {
        for var q: usize = 0; q < self.jobs.size(); ++q {
            if (self.jobs[q].kind != JobKind::Index) || self.jobs[q].progress.empty() {
                continue
            }

            var text: string = ""
            if !LinkFS::read(self.jobs[q].prog_file, &text) {
                continue
            }

            var n: i64 = 0
            for var c: usize = 0; c < text.size(); ++c {
                if (text[c] >= ('0' as u8)) && (text[c] <= ('9' as u8)) {
                    n = (n * 10) + ((text[c] - 48) as i64)
                }
            }

            if n == self.jobs[q].prog_n {
                continue
            }

            self.jobs[q].prog_n = n
            var m: i64 = 0
            var pe = self.entry_by_id(self.jobs[q].entry_id)
            if pe != usize::MAX {
                m = self.entries[pe].files.size() as i64
            }

            if m > 0 {
                var shown = if n > m => m else => n
                var pct = (shown * 100) / m
                if pct > 99 {
                    pct = 99
                }

                self.progress(self.jobs[q].progress, "report", f"{shown}/{m}", pct)
            } else {
                self.progress(self.jobs[q].progress, "report", f"{n} files", -1)
            }
        }
    }
}
