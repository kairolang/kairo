/// --- The Kairo Project ---------------------- Analyzer/Server/Server.k --- ///
///
///   The language server: owns the session and routes requests to providers.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   One loop, one thread. It waits a few tens of milliseconds for a message,
///   handles it, and then looks at its worker processes. Everything the
///   editor is told comes out of a SNAPSHOT: the JSON a worker wrote for one
///   entry point (Index/Worker.k). The server computes nothing about the
///   language itself; it frames, keeps buffers, starts workers and looks rows
///   up.
///
///   FRESHNESS. A request about a buffer that changed since its entry's last
///   snapshot is not answered from the old one: its positions would be off
///   by exactly the edit. It is parked, and answered when the worker for the
///   current text finishes. A request parked for about three seconds is
///   answered from the stale snapshot rather than left hanging.
///
///   CACHING. Nothing is analysed twice: an entry is re-run only when a file
///   in its import graph changed (in a buffer or on disk), the run starts
///   once typing pauses, and a worker that fails or crashes leaves the last
///   good snapshot in place.


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
import Server::Output::*
import Server::Scheduling::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*
import Server::SyntaxWorker::*

pub fn server_main(const self_path: string) -> i32 {
    var unsafe *s = kairo::std::create<Server>()
    finally {
        kairo::std::destroy(s)
    }

    s->exe = self_path
    s->tmp = LinkFS::temp_dir("kals")
    if s->tmp.empty() {
        io::eprintln("kals: cannot create a scratch directory")
        return 1
    }

    return s->run()
}

pub class Server {
    pub var t:       Transport
    pub var docs:    DocumentStore
    pub var project: Project

    pub var entries: [Entry]
    pub var jobs:    [Job]
    pub var parked:  [Parked]

    pub var exe:  string = ""  ///< this binary: workers are started from it
    pub var tmp:  string = ""  ///< scratch directory, removed at exit
    pub var root: string = ""  ///< workspace folder

    pub var turn: u64 = 0      ///< loop turns so far; a run's length is measured in them
    pub var rev:  u64 = 1      ///< bumped on every change to any buffer or file
    pub var seq:  u64 = 0      ///< names scratch files and outgoing requests

    pub var ready:           bool = false  ///< `initialized` arrived: notifications may be sent
    pub var quit:            bool = false
    pub var exit_code:       i32  = 1
    pub var shutdown_seen:   bool = false
    pub var refresh_tokens:  bool = false  ///< client honours semanticTokens/refresh
    pub var refresh_inlays:  bool = false
    pub var highlight_panics: bool = false ///< initializationOptions.highlightPanics: send `panics`

    /// Scratch files a finished worker may still have open; removed once no
    /// worker is running.
    pub var garbage: [string]

    /// The clangd bridge (section 15), one row per `.k` file a C or C++
    /// source of the project includes: its header once a job wrote one, the
    /// files its last check read ("\n"-joined: an edit to any of them, a
    /// module it re-exports from included, regenerates it), and whether it
    /// is due.
    pub var br_files:   [string]
    pub var br_hdr:     [string]
    pub var br_deps:    [string]
    pub var br_dirty:   [bool]
    pub var br_running: [bool]
    pub var br_rescan:  bool   = false  ///< a C/C++ source changed: find the includes again
    pub var br_mapped:  string = ""     ///< the mapping overlay.yaml was last written with

    /// The two debounces, in milliseconds since the last change to any
    /// buffer: a syntax-only pass of each edited buffer after syntax_ms
    /// (`initializationOptions.syntaxDebounceMs`; the fallback path only:
    /// the persistent syntax worker is fed on every change), the Sema run
    /// after debounce_ms (`debounceMs`). The syntax pass parses one file and so
    /// lands well before the run does; its errors and lexical tokens are what
    /// the editor shows meanwhile.
    pub var syn:     SyntaxChild    ///< the persistent syntax worker (SyntaxWorker.k)
    pub var syn_seq: i64 = 0        ///< ids of its requests

    pub var debounce_ms:    i64 = DEBOUNCE_MS
    pub var syntax_ms:      i64 = SYNTAX_DEBOUNCE_MS
    pub var last_change_ms: i64 = 0

    /// The client takes `window/workDoneProgress/create` (section 14).
    pub var progress_ok: bool = false

    /// Index workers allowed at once. Two for small graphs; a large graph
    /// always runs alone (see can_start).
    pub var max_index: usize = MAX_INDEX_WORKERS

    pub var refreshed_rev: u64 = 0  ///< the revision the last refresh request was sent for

    /// The last completion list's documentation, by label: handed out one
    /// item at a time on completionItem/resolve, so a list of hundreds does
    /// not carry hundreds of doc blocks.
    pub var item_labels: [string]
    pub var item_docs:   [string]

    /// The semantic tokens last sent per buffer, for the delta request: the
    /// URI, the result id it was sent under, and the integers.
    pub var tok_uri:  [string]
    pub var tok_id:   [u64]
    pub var tok_data: [[i64]]
    pub var tok_seq:  u64 = 0

    pub var trace_buf:   string = ""
    pub var trace_dirty: bool   = false

    pub var comp_wait:    string = ""
    pub var comp_wait_id: string = ""

    fn Server(self) = default

    // --- wire ------------------------------------------------------------

    /// Handles one message from the editor.
    fn handle(self, const msg: string) {
        var d = JsonDoc()
        if !d.parse(msg) {
            self.log(d.error)
            return
        }

        var method = d.get_str(d.root, "method")
        var idn    = d.get(d.root, "id")
        var has_id = idn != JSON_NONE()
        var id     = d.dump(idn)
        var params = d.get(d.root, "params")

        if method.empty() {
            self.trace("<- reply " + id)
            return // a reply to one of our own requests
        }

        var about = d.get_str(d.get(params, "textDocument"), "uri")
        if about.size() > 40 {
            about = about.subslice(about.size() - 40, 40)
        }

        self.trace(f"<- {id} {method} " + about)

        if method == M_INITIALIZE {
            // What the client says it supports decides what it will ask for;
            // when a feature never shows up in an editor, this is the first
            // thing to read.
            var td = d.get(d.get(params, "capabilities"), "textDocument")
            var have: string = "client textDocument capabilities:"
            var c = d.first(td)
            while c != JSON_NONE() {
                have += " "
                have += d.key(c)
                c = d.next(c)
            }

            self.trace(have)
            self.trace("client: " + d.dump(d.get(params, "clientInfo")))
            self.initialize(&d, params, id)
            return
        }

        if method == M_INITIALIZED {
            self.ready = true
            self.say(MSG_INFO, "kals started in " + self.root)
            self.load_project()
            self.br_rescan = true
            if self.project.path.empty() {
                self.say(MSG_INFO, "no kairo_compile.json found: each file is checked on its own")
            } else {
                self.say(MSG_INFO, f"project {self.project.path}: {self.project.entries.size()} entry point(s)")
            }

            return
        }

        if method == M_SHUTDOWN {
            self.shutdown_seen = true
            self.respond(id, "null")
            return
        }

        if method == M_EXIT {
            self.quit = true
            if self.shutdown_seen {
                self.exit_code = 0
            }

            return
        }

        if method == M_DID_OPEN {
            var td = d.get(params, "textDocument")
            var i  = self.docs.open(d.get_str(td, "uri"), d.get_int(td, "version"), d.get_str(td, "text"))
            self.docs.docs[i].path = Path::real_path_of(self.docs.docs[i].path)
            self.touch(self.docs.docs[i].path)
            self.ensure_entry(self.docs.docs[i].path)
            return
        }

        if method == M_DID_CHANGE {
            var td = d.get(params, "textDocument")
            var i  = self.docs.index_of(d.get_str(td, "uri"))
            if i != usize::MAX {
                self.docs.change(i, d.get_int(td, "version"), &d, d.get(params, "contentChanges"))
                self.touch(self.docs.docs[i].path)
            }

            return
        }

        if method == M_DID_CLOSE {
            var uri = d.get_str(d.get(params, "textDocument"), "uri")
            var i   = self.docs.index_of(uri)
            if i != usize::MAX {
                var path = self.docs.docs[i].path
                if !self.docs.docs[i].tmp_path.empty() {
                    self.garbage.push_back(self.docs.docs[i].tmp_path)
                }

                self.docs.close(uri)
                // The disk text is the truth again.
                self.touch(path)
            }

            return
        }

        if method == M_DID_SAVE {
            var path = self.path_of(d.get_str(d.get(params, "textDocument"), "uri"))
            if Path::filename_of(path) == project_file_name() {
                self.rev += 1
                self.load_project()
            } else {
                self.touch(path)
            }

            return
        }

        if method == M_DID_CHANGE_WATCHED {
            var c = d.first(d.get(params, "changes"))
            var reload = false
            while c != JSON_NONE() {
                var path = self.path_of(d.get_str(c, "uri"))
                if Path::filename_of(path) == project_file_name() {
                    reload = true
                } else if self.docs.index_of_path(path) == usize::MAX {
                    // An open buffer overrides the disk, so a disk change to
                    // it changes nothing the compiler sees.
                    self.touch(path)
                }

                c = d.next(c)
            }

            if reload {
                self.rev += 1
                self.load_project()
            }

            return
        }

        if method == M_FORMATTING {
            self.formatting(&d, params, id)
            return
        }

        if method == M_COMPLETION {
            self.completion(&d, params, id)
            return
        }

        // Answered from the buffer's text, so never parked and never stale.
        if method == M_FOLDING_RANGE {
            self.folding(&d, params, id)
            return
        }

        if method == M_SELECTION_RANGE {
            self.selection(&d, params, id)
            return
        }

        if method == M_SIGNATURE_HELP {
            self.signature_help(&d, params, id)
            return
        }

        if (method == M_INCOMING_CALLS) || (method == M_OUTGOING_CALLS) {
            self.calls(&d, d.get(params, "item"), method == M_INCOMING_CALLS, id)
            return
        }

        if (method == M_SUPERTYPES) || (method == M_SUBTYPES) {
            var item = d.get(params, "item")
            var sel  = d.get(d.get(item, "selectionRange"), "start")
            var w = JsonWriter()
            w.begin_array()
            self.related_types(
                self.path_of(d.get_str(item, "uri")),
                d.get_int(sel, "line"),
                d.get_int(sel, "character"),
                method == M_SUPERTYPES,
                &w,
                true,
            )

            w.end_array()
            self.respond(id, w.out)
            return
        }

        if method == M_RANGE_FORMATTING {
            self.formatting(&d, params, id)
            return
        }

        if method == M_COMPLETION_RESOLVE {
            // The item comes back as it was sent; its documentation is added
            // when the last list had some for that label.
            var out = d.dump(params)
            var label = d.get_str(params, "label")
            for var q: usize = 0; q < self.item_labels.size(); ++q {
                if (self.item_labels[q] == label) && (out.size() > 1) && (d.get(params, "documentation") == JSON_NONE()) {
                    var dw = JsonWriter()
                    dw.begin_object()
                    dw.field("kind", "markdown")
                    dw.field("value", self.item_docs[q])
                    dw.end_object()
                    out = out.subslice(0, out.size() - 1) + ",\"documentation\":" + dw.out + "}"
                    break
                }
            }

            self.respond(id, out)
            return
        }

        if method == M_ON_TYPE_FORMATTING {
            self.on_type(&d, params, id)
            return
        }

        if method == M_WORKSPACE_SYMBOL {
            self.workspace_symbols(d.get_str(params, "query"), id)
            return
        }

        if method.starts_with(M_TEXT_DOCUMENT_PREFIX) {
            if !self.feature(msg, false, false) {
                self.park(msg)
            }

            return
        }

        if method == M_CANCEL_REQUEST {
            // The editor has moved on: a request still waiting for a snapshot
            // is answered "cancelled" now rather than computed later, and a
            // completion still running is disowned (its worker finishes and
            // is ignored; a process cannot be recalled mid-compile).
            var want = d.dump(d.get(params, "id"))
            var kept: [Parked]
            for var q: usize = 0; q < self.parked.size(); ++q {
                var pd = JsonDoc()
                if pd.parse(self.parked[q].msg) && (pd.dump(pd.get(pd.root, "id")) == want) {
                    self.respond_error(want, ERR_REQUEST_CANCELLED, "cancelled")
                } else {
                    kept.push_back(self.parked[q])
                }
            }

            self.parked = kept
            for var q: usize = 0; q < self.jobs.size(); ++q {
                if (self.jobs[q].kind == JOB_COMPLETE()) && (self.jobs[q].id == want) && (!self.jobs[q].cancelled) {
                    self.jobs[q].cancelled = true
                    self.respond_error(want, ERR_REQUEST_CANCELLED, "cancelled")
                }
            }

            if (!self.comp_wait_id.empty()) && (self.comp_wait_id == want) {
                self.respond_error(want, ERR_REQUEST_CANCELLED, "cancelled")
                self.comp_wait    = ""
                self.comp_wait_id = ""
            }

            return
        }

        if method == M_KALS_TEXT {
            // Debug: what the server holds for a buffer, for a test to
            // compare with its own copy after a run of incremental edits.
            var i = self.docs.index_of(d.get_str(d.get(params, "textDocument"), "uri"))
            if i == usize::MAX {
                self.respond(id, "null")
                return
            }

            self.docs.docs[i].sync()
            var h = fnv1a(self.docs.docs[i].text)
            var w = JsonWriter()
            w.begin_object()
            w.field("hash", f"{h}")
            w.field_uint("size", self.docs.docs[i].text.size())
            w.field_uint("lines", self.docs.docs[i].buf.line_count())
            w.field_int("version", self.docs.docs[i].version)
            w.end_object()
            self.respond(id, w.out)
            return
        }

        if method.starts_with(M_DOLLAR_PREFIX) || (!has_id) {
            return // progress, and notifications we do not use
        }

        self.respond_error(id, ERR_METHOD_NOT_FOUND, "method not found: " + method)
    }

    fn run(self) -> i32 {
        while !self.quit {
            var got = self.wait_any(self.wait_ms())
            if got {
                self.handle(self.t.take())
                // The persistent syntax pass starts on the change itself, no
                // debounce; the worker being busy is the only thing it waits
                // for (one request in flight).
                self.syntax_kick()
                continue // drain the queue before starting anything else
            }

            if self.t.closed {
                break // the editor went away without `exit`
            }

            self.turn += 1
            self.reap()
            self.flush_trace()

            // A run that has outlasted a request's patience marks its entry
            // slow; what is parked on it is answered now, from what there is.
            var now = now_ms()
            for var q: usize = 0; q < self.jobs.size(); ++q {
                var je = self.jobs[q].entry
                if (self.jobs[q].kind == JOB_INDEX()) && (je < self.entries.size()) && (!self.entries[je].slow)
                    && ((now - self.jobs[q].started_ms) > SLOW_RUN_MS) {
                    self.entries[je].slow = true
                    self.retry_parked(false)
                }
            }

            self.report_progress()

            self.syntax_watch()
            self.syntax_kick()

            // The fallback path (no persistent worker): the syntax-only pass
            // of each edited buffer as a process, on its own (shorter)
            // debounce, one at a time per buffer.
            if self.syn.failed && ((now - self.last_change_ms) >= self.syntax_ms) {
                // At most two at once: each is a compiler process (about
                // 190 MB in a debug build), and a change that touches many
                // buffers (a rename) must not start one per buffer.
                for var k: usize = 0; k < self.docs.docs.size(); ++k {
                    if (!self.docs.docs[k].syn_running) && (self.docs.docs[k].changed_at > self.docs.docs[k].syn_started)
                        && (self.running(JOB_SYNTAX()) < MAX_SYNTAX_PASSES) {
                        self.start_syntax(k)
                    }
                }
            }

            // The wait timed out, so typing has paused: start what is due.
            // One run per entry at a time; a change that arrives during a
            // run leaves the entry dirty and it runs again when this one ends.
            //
            // Debounced (debounce_ms), and bounded (can_start): a project
            // file listing several entries must not start them all at once.
            if (now - self.last_change_ms) >= self.debounce_ms {
                for var i: usize = 0; i < self.entries.size(); ++i {
                    if self.entries[i].dirty && (!self.entries[i].running) && (!self.entries[i].entry.empty())
                        && self.can_start(i) {
                        self.start_index(i)
                    }
                }

                // The clangd bridge: on the same debounce as a run, one
                // header job at a time.
                if self.br_rescan {
                    self.bridge_scan_()
                }

                if self.running(JOB_HEADER()) == 0 {
                    for var b: usize = 0; b < self.br_files.size(); ++b {
                        if self.br_dirty[b] && (!self.br_running[b]) {
                            self.start_header_(b)
                            break
                        }
                    }
                }
            }

            if (!self.comp_wait.empty()) && (self.running(JOB_COMPLETE()) == 0) {
                var m = self.comp_wait
                self.comp_wait    = ""
                self.comp_wait_id = ""
                self.handle(m)
            }

            if !self.parked.empty() {
                self.retry_parked(true)
            }
        }

        self.syntax_stop()
        if !self.tmp.empty() {
            Path::remove_tree(self.tmp)
        }

        return self.exit_code
    }
}
