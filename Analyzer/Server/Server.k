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
ffi "c" import "kals_io.h"

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
import Server::CompletionWords::{
    BuiltinRow,
    Word,
}
import Server::Diagnostics::*
import Server::Features::*
import Server::Formatting::*
import Server::IndexCompletion::*
import Server::Lifecycle::*
import Server::LiveIndex::*
import Server::Lookup::*
import Server::Navigation::*
import Server::Output::*
import Server::Scheduling::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::SyntaxWorker::*
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

pub fn server_main(const self_path: string) -> i32 {
    var unsafe *s = kairo::std::create<Server>()
    finally {
        kairo::std::destroy(s)
    }

    s->exe = self_path
    s->read_debug_knobs_()
    s->tmp = LinkFS::temp_dir("kals")
    if s->tmp.empty() {
        io::eprintln("kals: cannot create a scratch directory")
        return 1
    }

    return s->run()
}

/// Where the LSP session is (the protocol's lifecycle): before the
/// `initialize` request only `exit` is taken; after its answer requests are
/// served; `initialized` lets the server send notifications of its own;
/// after `shutdown` nothing runs and only `exit` is taken.
pub enum Session derives u8 {
    AwaitInit,
    Initializing,
    Running,
    ShutDown,
}

pub class Server {
    pub var t:       Transport
    pub var docs:    DocumentStore
    pub var project: Project

    pub var entries:   [Entry]
    pub var entry_seq: u64      = 0 ///< the last Entry::id handed out
    pub var jobs:      [Job]
    pub var parked:    [Parked]

    pub var exe:  string = "" ///< this binary: workers are started from it
    pub var tmp:  string = "" ///< scratch directory, removed at exit
    pub var root: string = "" ///< workspace folder

    pub var rev: u64 = 1 ///< bumped on every change to any buffer or file
    pub var seq: u64 = 0 ///< names scratch files and outgoing requests

    pub var session:          Session = Session::AwaitInit
    pub var quit:             bool    = false
    pub var exit_code:        i32     = 1
    pub var refresh_tokens:   bool    = false ///< client honours semanticTokens/refresh
    pub var refresh_inlays:   bool    = false
    pub var highlight_panics: bool    = false ///< initializationOptions.highlightPanics: send `panics`

    /// Scratch files a finished worker may still have open; removed once no
    /// worker is running.
    pub var garbage: [string]

    /// The clangd bridge (section 15), one row per `.k` file a C or C++
    /// source of the project includes: its header once a job wrote one, the
    /// files its last check read ("\n"-joined: an edit to any of them, a
    /// module it re-exports from included, regenerates it), and whether it
    /// is due.
    pub var br_files:       [string]
    pub var br_hdr:         [string]
    pub var br_deps:        [string]
    pub var br_dirty:       [bool]
    pub var br_running:     [bool]
    pub var br_rescan:      bool     = false ///< a C/C++ source changed: find the includes again
    pub var br_told:        [string] ///< C/C++ sources the editor reported (watched files)
    pub var br_changed:     [string] ///< sources to read again on the next scan
    pub var br_src:         [string] ///< the last scan's sources, in order
    pub var br_src_inc:     [string] ///< and the `.k` includes of each, '\n'-terminated
    pub var watch_ok:       bool     = false ///< the client takes a dynamic didChangeWatchedFiles registration
    pub var br_ov_mtime:    u64      = 0 ///< overlay.yaml's mtime when this process last wrote or read it
    pub var br_ov_check_ms: i64      = 0 ///< when overlay.yaml was last looked at for another process's write
    pub var br_rank:        [usize] ///< per row: how recently a source including it was reported (0: never)
    pub var br_recent:      [string] ///< C/C++ sources reported changed, most recent last (BRIDGE_RECENT_SOURCES)
    pub var br_cxx_w:       [string] ///< per row: kcc's driver words for a C++ source including it ('\n'-terminated)
    pub var br_c_w:         [string] ///< per row: the same for a C source
    pub var br_src_seen:    [string] ///< per source: the headers its last scan read, '\n'-terminated
    pub var br_said:        string   = "" ///< the .clangd lines last suggested to the user (said once)

    /// The two debounces, in milliseconds since the last change to any
    /// buffer: a syntax-only pass of each edited buffer after syntax_ms
    /// (`initializationOptions.syntaxDebounceMs`; the fallback path only:
    /// the persistent syntax worker is fed on every change), the Sema run
    /// after debounce_ms (`debounceMs`). The syntax pass parses one file and so
    /// lands well before the run does; its errors and lexical tokens are what
    /// the editor shows meanwhile.
    pub var syn:     SyntaxChild     ///< the persistent syntax worker (SyntaxWorker.k)
    pub var syn_seq: i64         = 0 ///< ids of its requests

    /// An entry's graph is kept checked in a process that stays up and an
    /// edit is re-checked in place (LiveIndex.k). The default; off with
    /// initializationOptions.liveCheck: false or KALS_LIVE_CHECK=0, and
    /// then every run is a process.
    pub var live_on:  bool        = true
    pub var lives:    [LiveChild]
    pub var live_seq: i64         = 0

    pub var debounce_ms:    i64 = DEBOUNCE_MS
    pub var syntax_ms:      i64 = SYNTAX_DEBOUNCE_MS
    pub var last_change_ms: i64 = 0

    /// The client takes `window/workDoneProgress/create` (section 14).
    pub var progress_ok: bool = false

    /// Index workers allowed at once. Two for small graphs; a large graph
    /// always runs alone (see can_start).
    pub var max_index: usize = MAX_INDEX_WORKERS

    pub var refreshed_rev: u64 = 0 ///< the revision the last refresh request was sent for

    /// The last completion list's documentation, by label: handed out one
    /// item at a time on completionItem/resolve, so a list of hundreds does
    /// not carry hundreds of doc blocks.
    pub var item_labels: [string]
    pub var item_docs:   [string]

    /// Completion from the index (IndexCompletion.k). Off
    /// (`indexCompletion: false`, KALS_INDEX_COMPLETION=0): every list is
    /// the compiler's, for comparing the two.
    pub var index_completion: bool = true
    /// The client reads `itemDefaults.editRange` / takes snippets.
    pub var edit_default_ok: bool = false
    pub var snippet_ok:      bool = false
    /// The files the last list's items are declared in: an item's `data`
    /// names one by index, for its `///` block on resolve.
    pub var comp_paths: [string]
    /// The language's words, attributes and builtin macros, read from the
    /// compiler's tables on first use (CompletionWords.k).
    /// The last header listing (IndexCompletion.k, header_candidates_): the
    /// buffer, language and directory typed it was made for, when, and the
    /// candidates. A path is typed a letter at a time and a client that
    /// asks at each gets the listing it was just given.
    pub var hdr_key:    string       = ""
    pub var hdr_ms:     i64          = 0
    pub var hdr_cands:  [Cand]
    pub var words:      [Word]
    pub var attr_rows:  [BuiltinRow]
    pub var macro_rows: [BuiltinRow]

    /// The semantic tokens last sent per buffer, for the delta request: the
    /// URI, the result id it was sent under, and the integers.
    pub var tok_uri:  [string]
    pub var tok_id:   [u64]
    pub var tok_data: [[i64]]
    pub var tok_seq:  u64      = 0

    pub var trace_buf:   string = ""
    pub var trace_dirty: bool   = false

    pub var comp_wait:    string = ""
    pub var comp_wait_id: string = ""

    /// Worker launches refused in a row, and the time before which none is
    /// tried again (launch_job): a binary that cannot start is retried with
    /// a backoff, not on every loop turn.
    pub var launch_refusals: u32 = 0
    pub var launch_after_ms: i64 = 0

    /// KALS_DEBUG_LAUNCH_FAIL (a test knob, smoke.py): `kind=n,...` refuses
    /// the next n launches of each kind (index, syntax, header, complete,
    /// syntax-server) as if the process could not start.
    pub var dbg_fail_kind: [string]
    pub var dbg_fail_left: [u32]

    fn Server(self) = default

    /// `initialized` arrived: notifications of the server's own may be sent.
    fn ready(const self) -> bool {
        return (self.session == Session::Running) || (self.session == Session::ShutDown)
    }

    /// Ends all work: parked requests and a waiting completion are answered
    /// "cancelled", every worker is killed and reaped and its progress
    /// ended, the persistent and live workers are stopped. For `shutdown`
    /// and for the loop's end (an `exit` without one, or the editor gone),
    /// before the scratch directory the workers write into is removed.
    fn stop_work_(self) {
        for var q: usize = 0; q < self.parked.size(); ++q {
            var pd = JsonDoc()
            if pd.parse(self.parked[q].msg) {
                self.respond_error(
                    pd.dump(pd.get(pd.root, K_ID)),
                    ERR_REQUEST_CANCELLED,
                    "cancelled: the server is shutting down",
                )
            }
        }

        self.parked.clear()
        if !self.comp_wait_id.empty() {
            self.respond_error(
                self.comp_wait_id,
                ERR_REQUEST_CANCELLED,
                "cancelled: the server is shutting down",
            )
        }

        self.comp_wait    = ""
        self.comp_wait_id = ""
        for var q: usize = 0; q < self.jobs.size(); ++q {
            unsafe kals_kill(self.jobs[q].pi.Pid as i64)
            var emsg: cxx::std::string
            llvm::sys::Wait(
                self.jobs[q].pi,
                cxx::std::optional<u32>(cxx::std::nullopt),
                unsafe &emsg,
            )

            if (self.jobs[q].kind == JobKind::Complete) && (!self.jobs[q].cancelled) {
                self.respond_error(
                    self.jobs[q].id,
                    ERR_REQUEST_CANCELLED,
                    "cancelled: the server is shutting down",
                )
            }

            if !self.jobs[q].progress.empty() {
                self.progress(self.jobs[q].progress, "end", "", -1)
            }

            self.trace(
                f"stopped job rev={self.jobs[q].rev} kind=" + job_kind_name(
                    self.jobs[q].kind,
                ),
            )
        }

        self.jobs.clear()
        self.syntax_stop()
        // A completion a live worker was asked for is answered here:
        // stopping the worker would hand it to a process of its own.
        for var k: usize = 0; k < self.lives.size(); ++k {
            for var q: usize = 0; q < self.lives[k].asks.size(); ++q {
                self.respond_error(
                    self.lives[k].asks[q].lsp_id,
                    ERR_REQUEST_CANCELLED,
                    "cancelled: the server is shutting down",
                )

                self.garbage.push_back(self.lives[k].asks[q].out)
                self.garbage.push_back(self.lives[k].asks[q].marked)
            }

            self.lives[k].asks.clear()
        }

        self.live_stop_all()
    }

    // --- wire ------------------------------------------------------------

    /// Handles one message from the editor.
    fn handle(self, const msg: string) {
        var d = JsonDoc()
        if !d.parse(msg) {
            self.log(d.error)
            return
        }

        var method = d.get_str(d.root, K_METHOD)
        var idn    = d.get(d.root, K_ID)
        var has_id = idn != JSON_NONE()
        var id     = d.dump(idn)
        var params = d.get(d.root, K_PARAMS)

        if method.empty() {
            self.trace("<- reply " + id)
            return // a reply to one of our own requests
        }

        var about = text_document_uri(&d, params)
        if about.size() > 40 {
            about = about.subslice(about.size() - 40, 40)
        }

        self.trace(f"<- {id} {method} " + about)

        // The protocol's lifecycle. `exit` is taken in any state; before
        // `initialize` a request is answered ServerNotInitialized and a
        // notification dropped; after `shutdown` a request is answered
        // InvalidRequest (and nothing else is done).
        if method == M_EXIT {
            self.quit = true
            if self.session == Session::ShutDown {
                self.exit_code = 0
            }

            return
        }

        if (self.session == Session::AwaitInit) && (method != M_INITIALIZE) {
            if has_id {
                self.respond_error(
                    id,
                    ERR_SERVER_NOT_INITIALIZED,
                    "the server is not initialized: send initialize first",
                )
            }

            return
        }

        if self.session == Session::ShutDown {
            if has_id {
                self.respond_error(
                    id,
                    ERR_INVALID_REQUEST,
                    "the server is shut down: only exit is taken",
                )
            }

            return
        }

        if (method == M_INITIALIZE) && (self.session != Session::AwaitInit) {
            self.respond_error(
                id,
                ERR_INVALID_REQUEST,
                "initialize may only be sent once",
            )

            return
        }

        if method == M_INITIALIZE {
            // What the client says it supports decides what it will ask for;
            // when a feature never shows up in an editor, this is the first
            // thing to read.
            var td = d.get(d.get(params, K_CAPABILITIES), K_TEXT_DOCUMENT)
            var have: string = "client textDocument capabilities:"
            var c            = d.first(td)
            while c != JSON_NONE() {
                have += " "
                have += d.key(c)
                c = d.next(c)
            }

            self.trace(have)
            self.trace("client: " + d.dump(d.get(params, "clientInfo")))
            self.initialize(&d, params, id)
            self.session = Session::Initializing
            return
        }

        if method == M_INITIALIZED {
            self.session = Session::Running
            self.say(MSG_INFO, "kals started in " + self.root)
            self.load_project()
            self.br_rescan = true
            // The clangd bridge needs to hear of C/C++ sources too, and a
            // client watches only what its own configuration lists (Kairo
            // files): ask for them here, so every client sends them.
            if self.watch_ok {
                self.request_with(M_REGISTER_CAPABILITY, WATCH_REGISTRATION)
            }

            if self.project.path.empty() {
                self.say(
                    MSG_INFO,
                    "no kairo_compile.json found: each file is checked on its own",
                )
            } else {
                self.say(
                    MSG_INFO,
                    f"project {self.project.path}: {self.project.entries.size()} entry point(s)",
                )
            }

            return
        }

        if method == M_SHUTDOWN {
            self.stop_work_()
            self.session = Session::ShutDown
            self.respond(id, "null")
            return
        }

        if method == M_DID_OPEN {
            var td = d.get(params, K_TEXT_DOCUMENT)
            var i = self.docs.open(
                d.get_str(td, K_URI),
                d.get_int(td, K_VERSION),
                d.get_str(td, K_TEXT),
            )

            self.docs.docs[i].path = Path::real_path_of(self.docs.docs[i].path)
            // A buffer opened with the text its entry's last run read from
            // the disk, and indexed by that run, changes nothing the
            // compiler sees: the index answers for it as it is. Only the
            // buffer's own syntax pass is due.
            var oei = self.unchanged_on_disk_(i)
            if oei != usize::MAX {
                self.docs.docs[i].changed_at = self.entries[oei].idx_rev
                self.docs.docs[i].changed_ms = now_ms()
                // That run read the disk, which is this text (unchanged_on_disk_
                // compared them): the index's text for the buffer's later edits.
                self.docs.docs[i].set_indexed(
                    self.docs.docs[i].text,
                    self.entries[oei].idx_rev,
                    self.entries[oei].entry,
                )
            } else {
                self.touch(self.docs.docs[i].path)
            }

            self.ensure_entry(self.docs.docs[i].path)
            return
        }

        if method == M_DID_CHANGE {
            var td = d.get(params, K_TEXT_DOCUMENT)
            var i  = self.docs.index_of(d.get_str(td, K_URI))
            if i != usize::MAX {
                self.docs.change(
                    i,
                    d.get_int(td, K_VERSION),
                    &d,
                    d.get(params, K_CONTENT_CHANGES),
                )

                self.touch(self.docs.docs[i].path)
            }

            return
        }

        if method == M_DID_CLOSE {
            var uri = text_document_uri(&d, params)
            var i   = self.docs.index_of(uri)
            if i != usize::MAX {
                var path = self.docs.docs[i].path
                if !self.docs.docs[i].tmp_path.empty() {
                    self.garbage.push_back(self.docs.docs[i].tmp_path)
                }

                // The disk text is the truth again: a change only when the
                // buffer was closed with edits it never saved.
                var saved = self.unchanged_on_disk_(i) != usize::MAX
                self.docs.close(uri)
                if !saved {
                    self.touch(path)
                }
            }

            return
        }

        if method == M_DID_SAVE {
            var path = self.path_of(text_document_uri(&d, params))
            if Path::filename_of(path) == project_file_name() {
                self.rev += 1
                self.load_project()
            } else if (self.docs.index_of_path(path) == usize::MAX) || is_cxx_source(path) {
                // An open buffer overrides the disk (it is the worker's
                // overlay), so saving it changes nothing the compiler sees:
                // its text was analysed when it was typed.
                self.touch(path)
            }

            return
        }

        if method == M_DID_CHANGE_WATCHED {
            var c      = d.first(d.get(params, K_CHANGES))
            var reload = false
            while c != JSON_NONE() {
                var path = self.path_of(d.get_str(c, K_URI))
                if Path::filename_of(path) == project_file_name() {
                    reload = true
                } else if Path::filename_of(path) == "compile_commands.json" {
                    self.br_rescan = true // the bridge's list of sources
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
            self.calls(
                &d,
                d.get(params, K_ITEM),
                method == M_INCOMING_CALLS,
                id,
            )

            return
        }

        if (method == M_SUPERTYPES) || (method == M_SUBTYPES) {
            var item = d.get(params, K_ITEM)
            var sel  = d.get(d.get(item, K_SELECTION_RANGE), K_START)
            var w    = JsonWriter()
            w.begin_array()
            var nosh = LineShift() // an item from an answer already placed
            self.related_types(
                self.path_of(d.get_str(item, K_URI)),
                d.get_int(sel, K_LINE),
                d.get_int(sel, K_CHARACTER),
                method == M_SUPERTYPES,
                &w,
                true,
                &nosh,
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
            var out   = d.dump(params)
            var label = d.get_str(params, K_LABEL)
            for var q: usize = 0; q < self.item_labels.size(); ++q {
                if (self.item_labels[q] == label)
                    && (out.size() > 1)
                    && (d.get(params, K_DOCUMENTATION) == JSON_NONE()) {
                    var dw = JsonWriter()
                    dw.begin_object()
                    dw.field(K_KIND, MARKUP_MARKDOWN)
                    dw.field(K_VALUE, self.item_docs[q])
                    dw.end_object()
                    out = out.subslice(0, out.size() - 1) + ",\"documentation\":" + dw.out + "}"
                    break
                }
            }

            // An item answered from the index says where it is declared.
            if (d.get(params, K_DOCUMENTATION) == JSON_NONE())
                && (d.get(params, K_DATA) != JSON_NONE())
                && (out.size() > 1) {
                var doc = self.resolve_doc_(&d, params)
                if !doc.empty() {
                    var dw = JsonWriter()
                    dw.begin_object()
                    dw.field(K_KIND, MARKUP_MARKDOWN)
                    dw.field(K_VALUE, doc)
                    dw.end_object()
                    out = out.subslice(0, out.size() - 1) + ",\"documentation\":" + dw.out + "}"
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
            var want           = d.dump(d.get(params, K_ID))
            var kept: [Parked]
            for var q: usize = 0; q < self.parked.size(); ++q {
                var pd = JsonDoc()
                if pd.parse(self.parked[q].msg) && (pd.dump(pd.get(pd.root, K_ID)) == want) {
                    self.respond_error(want, ERR_REQUEST_CANCELLED, "cancelled")
                } else {
                    kept.push_back(self.parked[q])
                }
            }

            self.parked = kept
            for var q: usize = 0; q < self.jobs.size(); ++q {
                if (self.jobs[q].kind == JobKind::Complete)
                    && (self.jobs[q].id == want)
                    && (!self.jobs[q].cancelled) {
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
            var i = self.docs.index_of(text_document_uri(&d, params))
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
            w.field_int(K_VERSION, self.docs.docs[i].version)
            w.end_object()
            self.respond(id, w.out)
            return
        }

        if method == M_KALS_SNAPSHOT {
            var sei = self.entry_of(self.path_of(text_document_uri(&d, params)))
            if (sei == usize::MAX) || (!self.entries[sei].has_snap) {
                self.respond(id, "null")
                return
            }

            var w = JsonWriter()
            w.begin_object()
            if self.entries[sei].has_idx {
                w.field_raw(
                    SK_FILES,
                    self.entries[sei].idx.dump(
                        self.entries[sei].idx.get(
                            self.entries[sei].idx.root,
                            SK_FILES,
                        ),
                    ),
                )
            } else {
                w.field_raw(SK_FILES, "[]")
            }

            w.field_raw(
                SK_DIAGNOSTICS,
                self.entries[sei].snap.dump(
                    self.entries[sei].snap.get(
                        self.entries[sei].snap.root,
                        SK_DIAGNOSTICS,
                    ),
                ),
            )

            w.field_raw(
                SK_DEPS,
                self.entries[sei].snap.dump(
                    self.entries[sei].snap.get(
                        self.entries[sei].snap.root,
                        SK_DEPS,
                    ),
                ),
            )

            w.end_object()
            self.respond(id, w.out)
            return
        }

        if method.starts_with(M_DOLLAR_PREFIX) || (!has_id) {
            return // progress, and notifications we do not use
        }

        self.respond_error(
            id,
            ERR_METHOD_NOT_FOUND,
            "method not found: " + method,
        )
    }

    fn run(self) -> i32 {
        while !self.quit {
            var got = self.wait_any(self.wait_ms())
            if got {
                self.handle(self.t.take())
                // The persistent syntax pass starts on the change itself, no
                // debounce; the worker being busy is the only thing it waits
                // for (one request in flight).
                if self.session != Session::ShutDown {
                    self.syntax_kick()
                }

                continue // drain the queue before starting anything else
            }

            if self.t.closed {
                break // the editor went away without `exit`
            }

            // Shut down: nothing more is started or answered (stop_work_
            // ended what there was); only `exit` is waited for.
            if self.session == Session::ShutDown {
                continue
            }

            self.reap()
            self.flush_trace()

            // A run that has outlasted a request's patience marks its entry
            // slow; what is parked on it is answered now, from what there is.
            var now = now_ms()
            for var q: usize = 0; q < self.jobs.size(); ++q {
                var je = self.entry_by_id(self.jobs[q].entry_id)
                if (self.jobs[q].kind == JobKind::Index)
                    && (je != usize::MAX)
                    && (!self.entries[je].slow)
                    && ((now - self.jobs[q].started_ms) > SLOW_RUN_MS) {
                    self.entries[je].slow = true
                    self.retry_parked(false)
                }
            }

            self.report_progress()

            self.live_watch()
            self.syntax_watch()
            self.syntax_kick()

            // The fallback path (no persistent worker): the syntax-only pass
            // of each edited buffer as a process, on its own (shorter)
            // debounce, one at a time per buffer.
            if self.syn.failed() && ((now - self.last_change_ms) >= self.syntax_ms) {
                // At most two at once: each is a compiler process (about
                // 190 MB in a debug build), and a change that touches many
                // buffers (a rename) must not start one per buffer.
                for var k: usize = 0; k < self.docs.docs.size(); ++k {
                    if self.docs.docs[k].syn_due()
                        && (self.running(JobKind::Syntax) < MAX_SYNTAX_PASSES) {
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
                    if (!self.entries[i].dirty)
                        || self.entries[i].entry.empty()
                        || ((now - self.last_change_ms) < self.debounce_of(
                            self.entries[i].slow,
                        )) {
                        continue
                    }

                    // The live worker takes a request while it answers an
                    // older one (it joins them); a process per run does not.
                    if self.live_takes(i) {
                        if self.live_send(i) {
                            continue
                        }
                    }

                    if (!self.entries[i].running) && self.can_start(i) {
                        self.start_index(i)
                    }
                }

                // The clangd bridge: on the same debounce as a run, one
                // header job at a time.
                if self.br_rescan {
                    self.bridge_scan_()
                }

                if self.running(JobKind::Header) == 0 {
                    var b = self.bridge_next_()
                    if b != usize::MAX {
                        self.start_header_(b)
                    }
                }
            }

            // Another kals on this root (a second editor) rewrites
            // overlay.yaml from what it knows: merge this one's entries back.
            if (!self.br_files.empty())
                && ((now - self.br_ov_check_ms) >= BRIDGE_OVERLAY_CHECK_MS) {
                self.br_ov_check_ms = now
                if LinkFS::mtime(
                    Path::join_str(self.bridge_dir_(), "overlay.yaml"),
                ) != self.br_ov_mtime {
                    self.bridge_overlay_()
                }
            }

            if (!self.comp_wait.empty()) && (self.running(JobKind::Complete) == 0) {
                var m = self.comp_wait
                self.comp_wait    = ""
                self.comp_wait_id = ""
                self.handle(m)
            }

            if !self.parked.empty() {
                self.retry_parked(true)
            }
        }

        self.stop_work_()
        if !self.tmp.empty() {
            Path::remove_tree(self.tmp)
        }

        return self.exit_code
    }
}
