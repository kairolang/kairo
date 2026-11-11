/// --- The Kairo Project ---------------------------- Analyzer/Server.k --- ///
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
import Index::Indexer::{
    completion_marker,
    token_modifier_names,
    token_type_names,
}
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import Support::FileIO::Path::Path
import TextScan::{
    Span,
    call_at,
    spans,
}
import Workspace::CompileCommandsLoader::{
    Project,
    project_file_name,
}
import std::io

pub fn JOB_INDEX() -> u32 {
    return 0
}

pub fn JOB_COMPLETE() -> u32 {
    return 1
}

/// A syntax-only pass over one buffer (`kals --worker ... --syntax-only`):
/// its parse errors and lexical tokens, long before the Sema run lands.
pub fn JOB_SYNTAX() -> u32 {
    return 2
}

/// Milliseconds on a monotonic clock: debounce deadlines and run lengths.
pub fn now_ms() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    var d = cxx::std::chrono::duration_cast<cxx::std::chrono::milliseconds>(t.time_since_epoch())
    return d.count() as i64
}

/// True for an LSP Diagnostic code the parser (not Sema) reports: `S<n>`,
/// and not the semantic category `SC<n>`.
pub fn is_syntax_code(const code: string) -> bool {
    return (code.size() > 1) && (code[0] == 83) && (code[1] != 67)
}

/// How long a request may wait for a fresh snapshot before it is answered
/// from what there is, in milliseconds; and how long a request waits for an
/// entry's FIRST index before that is taken as not coming. Wall time, not
/// loop turns: a turn is as short as the next debounce deadline.
pub fn PARK_LIMIT_MS() -> i64 {
    return 3000
}

pub fn FIRST_INDEX_LIMIT_MS() -> i64 {
    return 120000
}

/// A worker process in flight.
pub class Job {
    pub var kind:   u32    = 0
    pub var entry:  usize  = 0
    pub var pi:     llvm::sys::ProcessInfo
    pub var out:    string = ""     ///< the JSON the worker writes
    pub var log:    string = ""     ///< its stdout and stderr
    pub var rev:    u64    = 0      ///< server revision the run saw
    pub var began:  u64    = 0      ///< loop turn the run started on
    pub var id:     string = ""     ///< JOB_COMPLETE: the request id, as JSON
    pub var path:   string = ""     ///< JOB_COMPLETE: the buffer completed in
    pub var member: bool   = false  ///< JOB_COMPLETE: after `.`, `->` or `::`
    pub var marked: string = ""     ///< JOB_COMPLETE: the marked copy of the buffer
    pub var edit:   string = ""     ///< JOB_COMPLETE: the range an accepted item replaces, as JSON
    pub var cancelled: bool = false ///< JOB_COMPLETE: already answered "cancelled"; drop the result
    pub var started_ms: i64 = 0

    /// JOB_INDEX: the work-done progress token shown for this run (empty:
    /// none), the file the worker counts checked files into, and the last
    /// count reported.
    pub var progress:  string = ""
    pub var prog_file: string = ""
    pub var prog_n:    i64    = -1

    fn Job(self) = default
}

/// One entry point: its command, its last snapshot, and how stale that is.
pub class Entry {
    pub var entry: string = ""
    pub var dir:   string = ""
    pub var args:  [string]

    /// A file no project entry reaches, checked as its own entry.
    pub var adhoc: bool = false

    /// Every file the last run read: what this entry must be re-run for.
    pub var files: [string]

    /// The last run's output: what the diagnostics are read from.
    pub var snap:     JsonDoc
    pub var has_snap: bool = false
    pub var snap_rev: u64  = 0   ///< revision `snap` was computed at

    /// The last run's output THAT INDEXED FILES. A buffer that stops parsing
    /// (every half-typed line) gets diagnostics and no index; replacing the
    /// index with nothing would blank the editor's highlighting, hover and
    /// jump on each keystroke, so the last good one stays until a run
    /// produces another.
    pub var idx:     JsonDoc
    pub var has_idx: bool = false
    pub var idx_rev: u64  = 0   ///< revision `idx` was computed at
    pub var ran:      bool = false  ///< a run finished, with or without a snapshot

    pub var dirty:      bool = true
    pub var running:    bool = false
    pub var change_rev: u64  = 0   ///< revision of the last change that touches it
    pub var done_rev:   u64  = 0   ///< revision its snapshot was computed at

    /// URIs that currently show diagnostics from this entry, so the ones a
    /// new run no longer reports can be cleared.
    pub var published: [string]

    /// A run of this entry takes longer than a request should wait (about a
    /// second). Requests are then answered from the last snapshot at once
    /// instead of being parked, and the editor is told to ask again when the
    /// run lands. A small project never sets this, and gets exact answers.
    pub var slow: bool = false

    /// A stale answer went out while a run was in flight.
    pub var owe_refresh: bool = false

    /// `idx` decoded once when it is installed (index_cache), so a request
    /// is a binary search and not a walk that re-reads every row: per file
    /// (by its node in `idx`) a slice of the ref rows, sorted by position as
    /// the worker wrote them, and a slice of the token integers.
    pub var cf_node: [u32]
    pub var cf_lo:   [usize]
    pub var cf_hi:   [usize]
    pub var cr_row:  [u32]
    pub var cr_line: [i64]
    pub var cr_ch:   [i64]
    pub var cr_len:  [i64]
    pub var ct_lo:   [usize]
    pub var ct_hi:   [usize]
    pub var ct_data: [i64]

    fn Entry(self) = default

    fn holds(const self, const path: string) -> bool {
        if self.entry == path {
            return true
        }

        for var i: usize = 0; i < self.files.size(); ++i {
            if self.files[i] == path {
                return true
            }
        }

        return false
    }

    fn fresh(const self) -> bool {
        return self.ran && (!self.dirty) && (!self.running) && (self.done_rev >= self.change_rev)
    }
}

/// A request waiting for a fresh snapshot.
pub class Parked {
    pub var msg:   string = ""
    pub var turns: u32    = 0
    pub var since: i64    = 0   ///< now_ms() when it was parked

    fn Parked(self) = default
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

    /// Scratch files a finished worker may still have open; removed once no
    /// worker is running.
    pub var garbage: [string]

    /// The two debounces, in milliseconds since the last change to any
    /// buffer: a syntax-only pass of each edited buffer after syntax_ms
    /// (`initializationOptions.syntaxDebounceMs`), the Sema run after
    /// debounce_ms (`debounceMs`). The syntax pass parses one file and so
    /// lands well before the run does; its errors and lexical tokens are what
    /// the editor shows meanwhile.
    pub var debounce_ms:    i64 = 150
    pub var syntax_ms:      i64 = 100
    pub var last_change_ms: i64 = 0

    /// The client takes `window/workDoneProgress/create` (section 14).
    pub var progress_ok: bool = false

    /// Index workers allowed at once. Two for small graphs; a large graph
    /// always runs alone (see can_start).
    pub var max_index: usize = 2

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

    /// A line for the person using the editor: it goes to the client's log
    /// for this server (`window/logMessage`, the "Kairo" output channel in
    /// VS Code, the language server log in Zed), to stderr, and to the
    /// trace. \p level is LSP's MessageType: 1 error, 2 warning, 3 info, 4 log.
    fn say(self, level: i64, const s: string) {
        io::eprintln("kals: " + s)
        self.trace("log " + s)
        if self.ready {
            var w = JsonWriter()
            w.begin_object()
            w.field_int("type", level)
            w.field("message", s)
            w.end_object()
            self.notify("window/logMessage", w.out)
        }
    }

    fn log(self, const s: string) {
        self.say(2, s)
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
        if self.trace_buf.size() > 262144 {
            self.trace_buf = self.trace_buf.subslice(self.trace_buf.size() - 131072, 131072)
        }
    }

    fn flush_trace(self) {
        if self.trace_dirty && (!self.tmp.empty()) {
            LinkFS::write(Path::join_str(self.tmp, "trace.log"), self.trace_buf)
            self.trace_dirty = false
        }
    }

    fn respond(self, const id: string, const result: string) {
        var m: string = "{\"jsonrpc\":\"2.0\",\"id\":"
        m += id
        m += ",\"result\":"
        m += result
        m += "}"
        var head = result
        if head.size() > 80 {
            head = head.subslice(0, 80)
        }

        self.trace(f"-> {id} {result.size()}B " + head)
        self.t.send(m)
    }

    fn respond_error(self, const id: string, code: i64, const message: string) {
        var w = JsonWriter()
        w.begin_object()
        w.field("jsonrpc", "2.0")
        w.field_raw("id", id)
        w.key("error")
        w.begin_object()
        w.field_int("code", code)
        w.field("message", message)
        w.end_object()
        w.end_object()
        self.trace(f"-> {id} ERROR {code} " + message)
        self.t.send(w.out)
    }

    fn notify(self, const method: string, const params: string) {
        self.trace(f"-> notify {method} {params.size()}B")
        var m: string = "{\"jsonrpc\":\"2.0\",\"method\":\""
        m += method
        m += "\",\"params\":"
        m += params
        m += "}"
        self.t.send(m)
    }

    /// A request of our own; the editor's reply carries no method and is
    /// dropped in handle().
    fn request(self, const method: string) {
        self.seq += 1
        var m: string = "{\"jsonrpc\":\"2.0\",\"id\":\"kals-"
        m += f"{self.seq}"
        m += "\",\"method\":\""
        m += method
        m += "\"}"
        self.t.send(m)
    }

    /// The same, with \p params (JSON).
    fn request_with(self, const method: string, const params: string) {
        self.seq += 1
        var m: string = "{\"jsonrpc\":\"2.0\",\"id\":\"kals-"
        m += f"{self.seq}"
        m += "\",\"method\":\""
        m += method
        m += "\",\"params\":"
        m += params
        m += "}"
        self.trace(f"-> request {method}")
        self.t.send(m)
    }

    /// One `$/progress` notification for \p token: \p kind is begin, report
    /// or end; \p pct < 0 leaves the percentage out (indeterminate).
    fn progress(self, const token: string, const kind: string, const message: string, pct: i64) {
        var w = JsonWriter()
        w.begin_object()
        w.field("token", token)
        w.key("value")
        w.begin_object()
        w.field("kind", kind)
        if kind == "begin" {
            w.field("title", "Indexing Kairo")
            w.field_bool("cancellable", false)
        }

        if !message.empty() {
            w.field("message", message)
        }

        if (pct >= 0) && (kind != "end") {
            w.field_int("percentage", pct)
        }

        w.end_object()
        w.end_object()
        self.notify("$/progress", w.out)
    }

    fn show(self, level: i64, const text: string) {
        var w = JsonWriter()
        w.begin_object()
        w.field_int("type", level)
        w.field("message", text)
        w.end_object()
        self.notify("window/showMessage", w.out)
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

    /// (Re)reads the project file and rebuilds the entry list from it.
    fn load_project(self) {
        self.project.load(self.root)
        if !self.project.error.empty() {
            self.show(2, self.project.error)
        }

        // Snapshots of the old list describe commands that may no longer
        // exist; start over. Anything parked is retried against the new list.
        for var i: usize = 0; i < self.entries.size(); ++i {
            self.clear_published_(i)
        }

        self.entries.clear()
        for var i: usize = 0; i < self.project.entries.size(); ++i {
            var e = Entry()
            e.entry      = self.project.entries[i].entry
            e.dir        = self.project.entries[i].dir
            e.args       = self.project.entries[i].args
            e.change_rev = self.rev
            // Not analysed until a buffer needs it (ensure_entry): a project
            // file may list a dozen entry points, each a whole compile.
            e.dirty = false
            self.entries.push_back(e)
        }
    }

    fn clear_published_(self, ei: usize) {
        for var i: usize = 0; i < self.entries[ei].published.size(); ++i {
            var w = JsonWriter()
            w.begin_object()
            w.field("uri", self.entries[ei].published[i])
            w.field_raw("diagnostics", "[]")
            w.end_object()
            self.notify("textDocument/publishDiagnostics", w.out)
        }

        self.entries[ei].published.clear()
    }

    /// The entry \p path belongs to, or usize::MAX when no entry is known to
    /// hold it yet.
    fn entry_of(const self, const path: string) -> usize {
        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].entry == path {
                return i
            }
        }

        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].holds(path) {
                return i
            }
        }

        return usize::MAX
    }

    /// How much of \p a and \p b's directory prefix is shared: the entry
    /// nearest a file in the tree is the likeliest to import it.
    fn shared_prefix(const self, const a: string, const b: string) -> usize {
        var n: usize = 0
        var last: usize = 0
        while (n < a.size()) && (n < b.size()) && (a[n] == b[n]) {
            if a[n] == 47 {
                last = n
            }

            n += 1
        }

        return last
    }

    /// Could entry \p ei's import graph reach \p path at all? Only when the
    /// file is under the entry file's own directory or one of its `-I` roots.
    fn could_hold(const self, ei: usize, const path: string) -> bool {
        var home = Path::parent_of(self.entries[ei].entry) + "/"
        if path.starts_with(home) {
            return true
        }

        for var a: usize = 0; (a + 1) < self.entries[ei].args.size(); ++a {
            if self.entries[ei].args[a] != "-I" {
                continue
            }

            var root = Path::absolute_if_exists(self.entries[ei].args[a + 1], self.entries[ei].dir)
            if !root.ends_with("/") {
                root = root + "/"
            }

            if path.starts_with(root) {
                return true
            }
        }

        return false
    }

    /// The entry for \p path. usize::MAX while that is not known yet.
    ///
    /// An entry that IS the file, or whose last run read it, answers at once.
    /// Otherwise the project's entries are tried ONE AT A TIME, nearest in
    /// the tree first, until one turns out to hold the file; only when all
    /// have run and none does is the file checked as its own entry.
    fn ensure_entry(self, const path: string) -> usize {
        var ei = self.entry_of(path)
        if ei != usize::MAX {
            if (!self.entries[ei].ran) && (!self.entries[ei].running) {
                self.entries[ei].dirty = true
            }

            return ei
        }

        if !path.ends_with(".k") {
            return usize::MAX
        }

        // Is a candidate already being tried?
        var best = usize::MAX
        var best_score: usize = 0
        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].adhoc || self.entries[i].ran || self.entries[i].entry.empty() {
                continue
            }

            // An entry can only import a file that lies under one of its
            // search roots or beside it. A scratch file at the top of a
            // repository is under none: it must not cost one whole compile
            // per entry before it is checked on its own.
            if !self.could_hold(i, path) {
                continue
            }

            if self.entries[i].running || self.entries[i].dirty {
                return usize::MAX
            }

            var score = self.shared_prefix(self.entries[i].entry, path) + 1
            if score > best_score {
                best       = i
                best_score = score
            }
        }

        if best != usize::MAX {
            self.entries[best].dirty      = true
            self.entries[best].change_rev = self.rev
            return usize::MAX
        }

        var e = Entry()
        e.entry      = path
        e.dir        = self.project.dir
        e.args       = self.project.default_args
        e.adhoc      = true
        e.change_rev = self.rev
        self.entries.push_back(e)
        return self.entries.size() - 1
    }

    /// Marks every entry that reads \p path as needing a run.
    fn touch(self, const path: string) {
        self.rev += 1
        self.last_change_ms = now_ms()
        var di = self.docs.index_of_path(path)
        if di != usize::MAX {
            self.docs.docs[di].changed_at = self.rev
        }

        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].holds(path) {
                self.entries[i].dirty      = true
                self.entries[i].change_rev = self.rev
            }
        }
    }

    // --- workers ---------------------------------------------------------

    fn scratch(self, const suffix: string) -> string {
        self.seq += 1
        return Path::join_str(self.tmp, f"k{self.seq}{suffix}")
    }

    /// Starts \p argv with its output in \p log. False when it could not start.
    fn launch(self, @inout argv: [string], const log: string, pi: *llvm::sys::ProcessInfo) -> bool {
        // LLVM's process API takes ArrayRefs; SmallVector is the container
        // that makes one without a C++ std container in this tree.
        var refs: llvm::SmallVector<llvm::StringRef, 24>
        for var i: usize = 0; i < argv.size(); ++i {
            refs.push_back(kairo::sref(argv[i]))
        }

        var nlog = kairo::std::to_std_string(log)
        var redir: llvm::SmallVector<cxx::std::optional<llvm::StringRef>, 3>
        redir.push_back(cxx::std::optional<llvm::StringRef>(cxx::std::nullopt))
        redir.push_back(cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)))
        redir.push_back(cxx::std::optional<llvm::StringRef>(llvm::StringRef(nlog)))

        var emsg:  cxx::std::string
        var failed = false
        *pi = llvm::sys::ExecuteNoWait(
            refs[0],
            llvm::ArrayRef<llvm::StringRef>(refs),
            cxx::std::optional<llvm::ArrayRef<llvm::StringRef>>(cxx::std::nullopt),
            llvm::ArrayRef<cxx::std::optional<llvm::StringRef>>(redir),
            0,
            unsafe &emsg,
            unsafe &failed,
        )

        return !failed
    }

    /// Runs \p argv to completion with its output in \p log; its exit code, or
    /// -1 when it could not start. For kfmt, which answers in milliseconds.
    fn run_and_wait(self, @inout argv: [string], const log: string) -> i32 {
        var pi: llvm::sys::ProcessInfo
        if !self.launch(&argv, log, &pi) {
            return -1
        }

        var emsg: cxx::std::string
        var done = llvm::sys::Wait(pi, cxx::std::optional<u32>(cxx::std::nullopt), unsafe &emsg)
        return done.ReturnCode
    }

    /// The worker command for entry \p ei. \p marked_path / \p marked_tmp
    /// substitute one buffer's text (a completion request's marked copy).
    fn worker_argv(self,
                   ei:                usize,
                   const out:         string,
                   const marked_path: string,
                   const marked_tmp:  string) -> [string] {
        self.docs.sync_all()
        var argv: [string]
        argv.push_back(self.exe)
        argv.push_back("--worker")
        argv.push_back(out)
        argv.push_back("--cwd")
        argv.push_back(self.entries[ei].dir)
        argv.push_back("--root")
        argv.push_back(self.project.dir)

        for var i: usize = 0; i < self.docs.docs.size(); ++i {
            var path = self.docs.docs[i].path
            // Before the first run the entry's files are unknown, so every
            // buffer is offered; one the graph never loads is ignored.
            if self.entries[ei].ran && (!self.entries[ei].holds(path)) {
                continue
            }

            if path == marked_path {
                continue
            }

            if (self.docs.docs[i].tmp_rev != self.docs.docs[i].revision) || self.docs.docs[i].tmp_path.empty() {
                if !self.docs.docs[i].tmp_path.empty() {
                    self.garbage.push_back(self.docs.docs[i].tmp_path)
                }

                self.docs.docs[i].tmp_path = self.scratch(".k")
                self.docs.docs[i].tmp_rev  = self.docs.docs[i].revision
                LinkFS::write(self.docs.docs[i].tmp_path, self.docs.docs[i].text)
            }

            argv.push_back("--overlay")
            argv.push_back(path)
            argv.push_back(self.docs.docs[i].tmp_path)
        }

        if !marked_path.empty() {
            argv.push_back("--overlay")
            argv.push_back(marked_path)
            argv.push_back(marked_tmp)
        }

        argv.push_back("--")
        for var i: usize = 0; i < self.entries[ei].args.size(); ++i {
            argv.push_back(self.entries[ei].args[i])
        }

        argv.push_back(self.entries[ei].entry)
        return argv
    }

    /// Workers of \p kind in flight.
    fn running(const self, kind: u32) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < self.jobs.size(); ++i {
            if self.jobs[i].kind == kind {
                n += 1
            }
        }

        return n
    }

    /// May entry \p ei start now? One worker is always allowed. A second runs
    /// beside it only when BOTH graphs are known to be small: a worker is a
    /// whole compile, and two of a large tree is tens of GB.
    fn can_start(const self, ei: usize) -> bool {
        var n = self.running(JOB_INDEX())
        if n == 0 {
            return true
        }

        if n >= self.max_index {
            return false
        }

        if (!self.entries[ei].ran) || (self.entries[ei].files.size() > 96) {
            return false
        }

        for var i: usize = 0; i < self.jobs.size(); ++i {
            if self.jobs[i].kind != JOB_INDEX() {
                continue
            }

            var o = self.jobs[i].entry
            if (o >= self.entries.size()) || (!self.entries[o].ran) || (self.entries[o].files.size() > 96) {
                return false
            }
        }

        return true
    }

    fn start_index(self, ei: usize) {
        var j = Job()
        j.kind  = JOB_INDEX()
        j.entry = ei
        j.out   = self.scratch(".json")
        j.log   = self.scratch(".log")
        j.rev   = self.rev
        j.began = self.turn
        j.started_ms = now_ms()

        var wargv = self.worker_argv(ei, j.out, "", "")
        self.entries[ei].dirty = false
        self.trace(f"index start entry={self.entries[ei].entry} rev={j.rev}")

        // A first analysis, or one already known to be slow, is long enough
        // that an editor showing nothing looks frozen: show progress. The
        // worker counts the files it has checked into a small file the loop
        // reads (section 14).
        var argv: [string]
        for var q: usize = 0; q < 3; ++q {
            argv.push_back(wargv[q])
        }

        var want = (!self.entries[ei].ran) || self.entries[ei].slow
        if want {
            j.prog_file = self.scratch(".prog")
            argv.push_back("--progress")
            argv.push_back(j.prog_file)
        }

        for var q: usize = 3; q < wargv.size(); ++q {
            argv.push_back(wargv[q])
        }

        if !self.launch(&argv, j.log, &j.pi) {
            self.log("cannot start a worker (" + self.exe + ")")
            self.entries[ei].ran      = true
            self.entries[ei].done_rev = j.rev
            return
        }

        // Only for a run that started: a begin is always followed by an end.
        if want && self.progress_ok {
            self.seq += 1
            j.progress = f"kals-index-{self.seq}"
            var cw = JsonWriter()
            cw.begin_object()
            cw.field("token", j.progress)
            cw.end_object()
            self.request_with("window/workDoneProgress/create", cw.out)
            var m = self.entries[ei].files.size() as i64
            if m > 0 {
                self.progress(j.progress, "begin", f"0/{m}", 0)
            } else {
                self.progress(j.progress, "begin", Path::filename_of(self.entries[ei].entry), -1)
            }
        } else if want {
            self.say(4, "indexing " + self.entries[ei].entry)
        }

        self.entries[ei].running = true
        self.jobs.push_back(j)
    }

    /// Looks at every worker; finishes the ones that have exited.
    fn reap(self) {
        var i: usize = 0
        while i < self.jobs.size() {
            var emsg: cxx::std::string
            var done = llvm::sys::Wait(
                self.jobs[i].pi,
                cxx::std::optional<u32>(0 as u32),
                unsafe &emsg,
            )

            if done.Pid == 0 {
                i += 1
                continue // still running
            }

            var j = self.jobs[i]
            // Order does not matter: swap the last one in and drop the tail.
            self.jobs[i] = self.jobs[self.jobs.size() - 1]
            self.jobs.pop_back()
            if j.kind == JOB_INDEX() {
                self.finish_index(&j, done.ReturnCode)
                if !j.progress.empty() {
                    self.progress(j.progress, "end", "", -1)
                }

                if !j.prog_file.empty() {
                    self.garbage.push_back(j.prog_file)
                }
            } else if j.kind == JOB_SYNTAX() {
                self.finish_syntax(&j, done.ReturnCode)
            } else {
                self.finish_complete(&j, done.ReturnCode)
            }

            self.garbage.push_back(j.out)
            self.garbage.push_back(j.log)
            if !j.marked.empty() {
                self.garbage.push_back(j.marked)
            }
        }

        if self.jobs.empty() && (!self.garbage.empty()) {
            // Only now: a running worker reads its overlays when it starts,
            // and a file removed under it would turn into an empty buffer.
            var keep: [string]
            for var g: usize = 0; g < self.garbage.size(); ++g {
                var live = false
                for var d: usize = 0; d < self.docs.docs.size(); ++d {
                    if self.docs.docs[d].tmp_path == self.garbage[g] {
                        live = true
                    }
                }

                if live {
                    keep.push_back(self.garbage[g])
                } else {
                    Path::remove_file(self.garbage[g])
                }
            }

            self.garbage = keep
        }
    }

    /// One notification per finished run, with the revision it saw and the
    /// revision now: a status display, or a test, can tell "caught up" (the
    /// two are equal) from "another run is due". `$/` marks it as one a
    /// client may ignore. Sent AFTER the run's diagnostics, so a client that
    /// waits for it has them.
    fn analysed_(self, ei: usize, j: *Job, rc: i32) {
        var aw = JsonWriter()
        aw.begin_object()
        aw.field("entry", self.entries[ei].entry)
        aw.field_uint("revision", j->rev as usize)
        aw.field_uint("current", self.entries[ei].change_rev as usize)
        aw.field_int("exitCode", rc as i64)
        aw.end_object()
        self.notify("$/kals/analysed", aw.out)
    }

    fn finish_index(self, j: *Job, rc: i32) {
        var ei = j->entry
        if ei >= self.entries.size() {
            return // the project was reloaded under this run
        }

        self.entries[ei].running  = false
        self.entries[ei].ran      = true
        self.entries[ei].done_rev = j->rev

        // Re-judged every run: an entry that got fast again (a release
        // build of the server, a smaller graph) goes back to exact answers.
        var took = now_ms() - j->started_ms
        self.entries[ei].slow = took > 1000
        self.trace(f"index done entry={self.entries[ei].entry} rc={rc} rev={j->rev}")

        var text: string = ""
        var doc = JsonDoc()
        var ok  = LinkFS::read(j->out, &text) && doc.parse(text) && doc.get_bool(doc.root, "ok")
        if !ok {
            // A crash (no output) or a refused command line. The last good
            // snapshot stays; say why once, where the user can find it.
            var why = doc.get_str(doc.root, "error")
            if why.empty() {
                var tail: string = ""
                LinkFS::read(j->log, &tail)
                if tail.size() > 600 {
                    tail = tail.subslice(tail.size() - 600, 600)
                }

                why = f"the analysis of {self.entries[ei].entry} stopped (exit {rc}); showing the last good results\n" + tail
            }

            self.say(2, why)
            self.analysed_(ei, j, rc)
            self.retry_parked(false)
            return
        }

        // The first result for an entry, and any run slow enough to be felt,
        // is worth a line; a run per keystroke on a small project is not.
        if (!self.entries[ei].has_snap) || (took > 1000) {
            var nd = doc.count(doc.get(doc.root, "diagnostics"))
            var nf = doc.count(doc.get(doc.root, "deps"))
            self.say(4, f"analysed {self.entries[ei].entry}: {nf} files, {nd} diagnostics, {took} ms")
        }

        self.entries[ei].snap     = doc
        self.entries[ei].has_snap = true
        self.entries[ei].snap_rev = j->rev
        if doc.count(doc.get(doc.root, "files")) > 0 {
            self.entries[ei].idx     = doc
            self.entries[ei].has_idx = true
            self.entries[ei].idx_rev = j->rev
            self.index_cache(ei)
        }

        // The graph may have grown or shrunk with this edit.
        self.entries[ei].files.clear()
        var d = self.entries[ei].snap.first(self.entries[ei].snap.get(self.entries[ei].snap.root, "deps"))
        while d != JSON_NONE() {
            self.entries[ei].files.push_back(self.entries[ei].snap.str(d))
            d = self.entries[ei].snap.next(d)
        }

        // A stand-alone entry for a file this run turned out to hold is
        // redundant now: the project entry answers for it.
        if !self.entries[ei].adhoc {
            for var k: usize = 0; k < self.entries.size(); ++k {
                if self.entries[k].adhoc && self.entries[ei].holds(self.entries[k].entry) {
                    self.clear_published_(k)
                    self.entries[k].files.clear()
                    self.entries[k].entry    = ""
                    self.entries[k].has_snap = false
                    self.entries[k].has_idx  = false
                    self.entries[k].dirty    = false
                }
            }
        }

        self.publish(ei)
        self.analysed_(ei, j, rc)

        // A buffer this run turned out NOT to hold still needs an entry: try
        // the next candidate (or check it on its own).
        for var k: usize = 0; k < self.docs.docs.size(); ++k {
            self.ensure_entry(self.docs.docs[k].path)
        }

        self.retry_parked(false)

        // A refresh request is for results that changed with NO edit in the
        // buffer they belong to: an open file whose import was edited. Sent
        // after every run it does harm instead: the editor that just drew
        // the answer to its own request is told to throw it away (Zed then
        // shows no semantic tokens at all). So only when some OTHER buffer of
        // this entry is open, and never for the run a buffer's own edit
        // caused.
        var others: usize = 0
        for var k: usize = 0; k < self.docs.docs.size(); ++k {
            if self.entries[ei].holds(self.docs.docs[k].path) {
                others += 1
            }
        }

        if self.entries[ei].owe_refresh {
            others = 2
            self.entries[ei].owe_refresh = false
        }

        if (others > 1) && self.refreshed_rev != j->rev {
            self.refreshed_rev = j->rev
            if self.refresh_tokens {
                self.request("workspace/semanticTokens/refresh")
            }

            if self.refresh_inlays {
                self.request("workspace/inlayHint/refresh")
            }
        }
    }

    /// Sends this entry's diagnostics, one notification per file, and clears
    /// the files that had some last time and have none now.
    fn publish(self, ei: usize) {
        var *s = &self.entries[ei].snap
        var diags = s->get(s->root, "diagnostics")

        var paths: [string]
        var d = s->first(diags)
        while d != JSON_NONE() {
            var p = s->get_str(d, "path")
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
            if self.docs.docs[k].syn_landed && (self.docs.docs[k].syn_at > self.entries[ei].snap_rev)
                && self.entries[ei].holds(dp) {
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
            w.field("uri", uri)
            w.field_raw("diagnostics", arr)
            w.end_object()
            self.notify("textDocument/publishDiagnostics", w.out)
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
                w.field("uri", self.entries[ei].published[i])
                w.field_raw("diagnostics", "[]")
                w.end_object()
                self.notify("textDocument/publishDiagnostics", w.out)
            }
        }

        self.entries[ei].published = now
    }

    // --- snapshot lookups ------------------------------------------------

    /// Node of \p path's object in entry \p ei's snapshot, or JSON_NONE.
    fn file_node(self, ei: usize, const path: string) -> u32 {
        if (ei >= self.entries.size()) || (!self.entries[ei].has_idx) {
            return JSON_NONE()
        }

        var *s = &self.entries[ei].idx
        var f = s->first(s->get(s->root, "files"))
        while f != JSON_NONE() {
            if s->get_str(f, "path") == path {
                return f
            }

            f = s->next(f)
        }

        return JSON_NONE()
    }

    /// The \p n-th element of array node \p arr.
    fn nth(const self, s: *const JsonDoc, arr: u32, n: i64) -> u32 {
        var c = s->first(arr)
        var k: i64 = 0
        while (c != JSON_NONE()) && (k < n) {
            c = s->next(c)
            k += 1
        }

        return c
    }

    /// Decodes entry \p ei's `idx` into the cf_/cr_/ct_ tables. Once per
    /// installed index: what every request after it reads.
    fn index_cache(self, ei: usize) {
        var *e = &self.entries[ei]
        e->cf_node.clear()
        e->cf_lo.clear()
        e->cf_hi.clear()
        e->cr_row.clear()
        e->cr_line.clear()
        e->cr_ch.clear()
        e->cr_len.clear()
        e->ct_lo.clear()
        e->ct_hi.clear()
        e->ct_data.clear()
        var *s = &e->idx
        var f = s->first(s->get(s->root, "files"))
        while f != JSON_NONE() {
            e->cf_node.push_back(f)
            e->cf_lo.push_back(e->cr_row.size())
            var r = s->first(s->get(f, "refs"))
            while r != JSON_NONE() {
                var a = s->first(r)
                var b = s->next(a)
                var c = s->next(b)
                e->cr_row.push_back(r)
                e->cr_line.push_back(s->as_int(a))
                e->cr_ch.push_back(s->as_int(b))
                e->cr_len.push_back(s->as_int(c))
                r = s->next(r)
            }

            e->cf_hi.push_back(e->cr_row.size())
            e->ct_lo.push_back(e->ct_data.size())
            var t = s->first(s->get(f, "tokens"))
            while t != JSON_NONE() {
                e->ct_data.push_back(s->as_int(t))
                t = s->next(t)
            }

            e->ct_hi.push_back(e->ct_data.size())
            f = s->next(f)
        }
    }

    /// Slot of file node \p f in entry \p ei's cache, or usize::MAX.
    fn cache_slot(const self, ei: usize, f: u32) -> usize {
        for var k: usize = 0; k < self.entries[ei].cf_node.size(); ++k {
            if self.entries[ei].cf_node[k] == f {
                return k
            }
        }

        return usize::MAX
    }

    /// The ref row of file node \p f covering (line, ch), or JSON_NONE. The
    /// rows are sorted by position: a binary search for the line, then the
    /// few rows on it.
    fn ref_at(const self, ei: usize, f: u32, line: i64, ch: i64) -> u32 {
        var k = self.cache_slot(ei, f)
        if k != usize::MAX {
            var e: *const Entry = &self.entries[ei]
            var lo = e->cf_lo[k]
            var hi = e->cf_hi[k]
            while lo < hi {
                var mid = (lo + hi) / 2
                if e->cr_line[mid] < line {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            var q = lo
            while (q < e->cf_hi[k]) && (e->cr_line[q] == line) && (e->cr_ch[q] <= ch) {
                if ch <= (e->cr_ch[q] + e->cr_len[q]) {
                    return e->cr_row[q]
                }

                q += 1
            }

            return JSON_NONE()
        }

        var s: *const JsonDoc = &self.entries[ei].idx
        var r = s->first(s->get(f, "refs"))
        while r != JSON_NONE() {
            var a = s->first(r)
            var b = s->next(a)
            var c = s->next(b)
            if (s->as_int(a) == line) && (s->as_int(b) <= ch) && (ch <= (s->as_int(b) + s->as_int(c))) {
                return r
            }

            r = s->next(r)
        }

        return JSON_NONE()
    }

    fn write_range(self, w: *JsonWriter, line: i64, ch: i64, len: i64) {
        w->begin_object()
        w->key("start")
        w->begin_object()
        w->field_int("line", line)
        w->field_int("character", ch)
        w->end_object()
        w->key("end")
        w->begin_object()
        w->field_int("line", line)
        w->field_int("character", ch + len)
        w->end_object()
        w->end_object()
    }

    /// Every use of the declaration ref row \p row names, across every
    /// snapshot, as (uri, line, ch, len) written through \p emit_kind:
    /// 0 = Location objects, 1 = DocumentHighlight (same file only),
    /// 2 = TextEdit grouped by uri (rename).
    fn uses(self,
            s:              *const JsonDoc,
            f:              u32,
            row:            u32,
            w:              *JsonWriter,
            mode:           u32,
            const only:     string,
            const new_name: string,
            with_decl:      bool) {
        var def_file = s->as_int(self.nth(s, row, 3))
        if def_file < 0 {
            return
        }

        var def_path = s->str(self.nth(s, s->get(f, "files"), def_file))
        var def_line = s->as_int(self.nth(s, row, 4))
        var def_ch   = s->as_int(self.nth(s, row, 5))

        // A file can be indexed under more than one entry; report each
        // location once.
        var seen: [string]

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var path = o->get_str(of, "path")
                if (!only.empty()) && (path != only) {
                    of = o->next(of)
                    continue
                }

                var uri   = self.uri_of(path)
                var opened = false
                var r = o->first(o->get(of, "refs"))
                while r != JSON_NONE() {
                    var fi = o->as_int(self.nth(o, r, 3))
                    var same = (fi >= 0)
                        && (o->as_int(self.nth(o, r, 4)) == def_line)
                        && (o->as_int(self.nth(o, r, 5)) == def_ch)
                        && (o->str(self.nth(o, o->get(of, "files"), fi)) == def_path)
                    if same && (with_decl || (o->as_int(self.nth(o, r, 8)) == 0)) {
                        var line = o->as_int(self.nth(o, r, 0))
                        var ch   = o->as_int(self.nth(o, r, 1))
                        var len  = o->as_int(self.nth(o, r, 2))
                        var key  = f"{path}:{line}:{ch}"
                        var dup  = false
                        for var k: usize = 0; k < seen.size(); ++k {
                            if seen[k] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            if mode == 0 {
                                w->begin_object()
                                w->field("uri", uri)
                                w->key("range")
                                self.write_range(w, line, ch, len)
                                w->end_object()
                            } else if mode == 1 {
                                w->begin_object()
                                w->key("range")
                                self.write_range(w, line, ch, len)
                                w->field_int("kind", 1)
                                w->end_object()
                            } else {
                                if !opened {
                                    w->key(uri)
                                    w->begin_array()
                                    opened = true
                                }

                                w->begin_object()
                                w->key("range")
                                self.write_range(w, line, ch, len)
                                w->field("newText", new_name)
                                w->end_object()
                            }
                        }
                    }

                    r = o->next(r)
                }

                if opened {
                    w->end_array()
                }

                of = o->next(of)
            }
        }
    }

    // --- the syntax-only pass ---------------------------------------------

    /// How long the loop may wait for a message: the transport's 40 ms, or
    /// less when a debounce deadline falls sooner, so a pass starts on time
    /// rather than on the next 40 ms boundary.
    fn wait_ms(const self) -> i32 {
        // Only what the loop would START when the wait ends: an entry that
        // can_start refuses (another run holds the slot) is no deadline, or
        // the loop would spin at 1 ms turns for the whole of that run. A
        // deadline already passed is started on this turn, so it is not one
        // either.
        var best: i64 = 40
        var since = now_ms() - self.last_change_ms
        var syn_due = false
        for var k: usize = 0; k < self.docs.docs.size(); ++k {
            if (!self.docs.docs[k].syn_running) && (self.docs.docs[k].changed_at > self.docs.docs[k].syn_started) {
                syn_due = true
            }
        }

        var left = self.syntax_ms - since
        if syn_due && (left > 0) && (left < best) {
            best = left
        }

        var run_due = false
        for var k: usize = 0; k < self.entries.size(); ++k {
            if self.entries[k].dirty && (!self.entries[k].running) && (!self.entries[k].entry.empty())
                && self.can_start(k) {
                run_due = true
            }
        }

        left = self.debounce_ms - since
        if run_due && (left > 0) && (left < best) {
            best = left
        }

        return best as i32
    }

    /// Reads each progress-reporting worker's count of checked files and
    /// reports it when it moved: `N/M`, M being the files the entry's last
    /// run read (unknown on a very first run: a count without a percentage).
    fn report_progress(self) {
        for var q: usize = 0; q < self.jobs.size(); ++q {
            if (self.jobs[q].kind != JOB_INDEX()) || self.jobs[q].progress.empty() {
                continue
            }

            var text: string = ""
            if !LinkFS::read(self.jobs[q].prog_file, &text) {
                continue
            }

            var n: i64 = 0
            for var c: usize = 0; c < text.size(); ++c {
                if (text[c] >= 48) && (text[c] <= 57) {
                    n = (n * 10) + ((text[c] - 48) as i64)
                }
            }

            if n == self.jobs[q].prog_n {
                continue
            }

            self.jobs[q].prog_n = n
            var m: i64 = 0
            if self.jobs[q].entry < self.entries.size() {
                m = self.entries[self.jobs[q].entry].files.size() as i64
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

    /// Starts the syntax-only pass of buffer \p di: its current text, parsed
    /// alone (no imports, no Sema).
    fn start_syntax(self, di: usize) {
        self.docs.docs[di].sync()
        if (self.docs.docs[di].tmp_rev != self.docs.docs[di].revision) || self.docs.docs[di].tmp_path.empty() {
            if !self.docs.docs[di].tmp_path.empty() {
                self.garbage.push_back(self.docs.docs[di].tmp_path)
            }

            self.docs.docs[di].tmp_path = self.scratch(".k")
            self.docs.docs[di].tmp_rev  = self.docs.docs[di].revision
            LinkFS::write(self.docs.docs[di].tmp_path, self.docs.docs[di].text)
        }

        var j = Job()
        j.kind       = JOB_SYNTAX()
        j.path       = self.docs.docs[di].path
        j.out        = self.scratch(".json")
        j.log        = self.scratch(".log")
        j.rev        = self.rev
        j.began      = self.turn
        j.started_ms = now_ms()

        var argv: [string]
        argv.push_back(self.exe)
        argv.push_back("--worker")
        argv.push_back(j.out)
        argv.push_back("--syntax-only")
        argv.push_back(j.path)
        argv.push_back("--overlay")
        argv.push_back(j.path)
        argv.push_back(self.docs.docs[di].tmp_path)
        argv.push_back("--")
        argv.push_back(j.path)

        self.docs.docs[di].syn_started = self.docs.docs[di].changed_at
        if !self.launch(&argv, j.log, &j.pi) {
            return
        }

        self.docs.docs[di].syn_running = true
        self.trace(f"syntax start rev={j.rev} " + j.path)
        self.jobs.push_back(j)
    }

    fn finish_syntax(self, j: *Job, rc: i32) {
        var di = self.docs.index_of_path(j->path)
        if di == usize::MAX {
            return // closed meanwhile
        }

        self.docs.docs[di].syn_running = false
        var took = now_ms() - j->started_ms
        self.trace(f"syntax done rc={rc} rev={j->rev} {took} ms " + j->path)

        var text: string = ""
        var doc = JsonDoc()
        if !(LinkFS::read(j->out, &text) && doc.parse(text) && doc.get_bool(doc.root, "ok")) {
            return // a crash costs the fast path only; the Sema run still comes
        }

        if self.docs.docs[di].syn_landed && (j->rev < self.docs.docs[di].syn_at) {
            return
        }

        var *dd = &self.docs.docs[di]
        dd->syn_landed = true
        dd->syn_at     = j->rev
        dd->syn_parsed = doc.get_bool(doc.root, "parsed")
        dd->syn_diags  = ""
        var x = doc.first(doc.get(doc.root, "diagnostics"))
        while x != JSON_NONE() {
            if !dd->syn_diags.empty() {
                dd->syn_diags += ","
            }

            dd->syn_diags += doc.dump(doc.get(x, "diag"))
            x = doc.next(x)
        }

        dd->syn_tokens.clear()
        var t = doc.first(doc.get(doc.root, "tokens"))
        while t != JSON_NONE() {
            dd->syn_tokens.push_back(doc.as_int(t))
            t = doc.next(t)
        }

        self.publish_syntax(di)
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
        var have_snap = (ei != usize::MAX) && self.entries[ei].has_snap
        var syn_newer = (di != usize::MAX) && self.docs.docs[di].syn_landed
            && ((!have_snap) || (self.docs.docs[di].syn_at > self.entries[ei].snap_rev))
        if syn_newer && (!self.docs.docs[di].syn_diags.empty()) {
            out += self.docs.docs[di].syn_diags
            *n = 1
        }

        if have_snap {
            var *s = &self.entries[ei].snap
            var d = s->first(s->get(s->root, "diagnostics"))
            while d != JSON_NONE() {
                var p = s->get_str(d, "path")
                if p.empty() {
                    p = self.entries[ei].entry
                }

                var dg = s->get(d, "diag")
                if (p == path) && ((!syn_newer) || (!is_syntax_code(s->get_str(dg, "code")))) {
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
        if (ei != usize::MAX) && self.entries[ei].has_snap && (self.entries[ei].snap_rev >= self.docs.docs[di].syn_at) {
            return
        }

        var n: usize = 0
        var arr = self.compose_diags(ei, path, &n)
        var w = JsonWriter()
        w.begin_object()
        w.field("uri", self.docs.docs[di].uri)
        w.field_raw("diagnostics", arr)
        w.end_object()
        self.notify("textDocument/publishDiagnostics", w.out)

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

    // --- parking ---------------------------------------------------------

    fn park(self, const msg: string) {
        var p = Parked()
        p.msg   = msg
        p.since = now_ms()
        self.parked.push_back(p)
    }

    /// Runs every parked request again. With \p force, the ones that have
    /// waited too long are answered from whatever snapshot there is.
    fn retry_parked(self, force: bool) {
        var old = self.parked
        self.parked.clear()
        for var i: usize = 0; i < old.size(); ++i {
            var waited = now_ms() - old[i].since
            var stale  = force && (waited >= PARK_LIMIT_MS())
            // A first index that has not come after two minutes is not coming.
            if !self.feature(old[i].msg, stale, waited >= FIRST_INDEX_LIMIT_MS()) {
                var p = old[i]
                p.turns += 1
                self.parked.push_back(p)
            }
        }
    }

    // --- requests --------------------------------------------------------

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

        if method == "initialize" {
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

        if method == "initialized" {
            self.ready = true
            self.say(3, "kals started in " + self.root)
            self.load_project()
            if self.project.path.empty() {
                self.say(3, "no kairo_compile.json found: each file is checked on its own")
            } else {
                self.say(3, f"project {self.project.path}: {self.project.entries.size()} entry point(s)")
            }

            return
        }

        if method == "shutdown" {
            self.shutdown_seen = true
            self.respond(id, "null")
            return
        }

        if method == "exit" {
            self.quit = true
            if self.shutdown_seen {
                self.exit_code = 0
            }

            return
        }

        if method == "textDocument/didOpen" {
            var td = d.get(params, "textDocument")
            var i  = self.docs.open(d.get_str(td, "uri"), d.get_int(td, "version"), d.get_str(td, "text"))
            self.docs.docs[i].path = Path::real_path_of(self.docs.docs[i].path)
            self.touch(self.docs.docs[i].path)
            self.ensure_entry(self.docs.docs[i].path)
            return
        }

        if method == "textDocument/didChange" {
            var td = d.get(params, "textDocument")
            var i  = self.docs.index_of(d.get_str(td, "uri"))
            if i != usize::MAX {
                self.docs.change(i, d.get_int(td, "version"), &d, d.get(params, "contentChanges"))
                self.touch(self.docs.docs[i].path)
            }

            return
        }

        if method == "textDocument/didClose" {
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

        if method == "textDocument/didSave" {
            var path = self.path_of(d.get_str(d.get(params, "textDocument"), "uri"))
            if Path::filename_of(path) == project_file_name() {
                self.rev += 1
                self.load_project()
            } else {
                self.touch(path)
            }

            return
        }

        if method == "workspace/didChangeWatchedFiles" {
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

        if method == "textDocument/formatting" {
            self.formatting(&d, params, id)
            return
        }

        if method == "textDocument/completion" {
            self.completion(&d, params, id)
            return
        }

        // Answered from the buffer's text, so never parked and never stale.
        if method == "textDocument/foldingRange" {
            self.folding(&d, params, id)
            return
        }

        if method == "textDocument/selectionRange" {
            self.selection(&d, params, id)
            return
        }

        if method == "textDocument/signatureHelp" {
            self.signature_help(&d, params, id)
            return
        }

        if (method == "callHierarchy/incomingCalls") || (method == "callHierarchy/outgoingCalls") {
            self.calls(&d, d.get(params, "item"), method == "callHierarchy/incomingCalls", id)
            return
        }

        if (method == "typeHierarchy/supertypes") || (method == "typeHierarchy/subtypes") {
            var item = d.get(params, "item")
            var sel  = d.get(d.get(item, "selectionRange"), "start")
            var w = JsonWriter()
            w.begin_array()
            self.related_types(
                self.path_of(d.get_str(item, "uri")),
                d.get_int(sel, "line"),
                d.get_int(sel, "character"),
                method == "typeHierarchy/supertypes",
                &w,
                true,
            )

            w.end_array()
            self.respond(id, w.out)
            return
        }

        if method == "textDocument/rangeFormatting" {
            self.formatting(&d, params, id)
            return
        }

        if method == "completionItem/resolve" {
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

        if method == "textDocument/onTypeFormatting" {
            self.on_type(&d, params, id)
            return
        }

        if method == "workspace/symbol" {
            self.workspace_symbols(d.get_str(params, "query"), id)
            return
        }

        if method.starts_with("textDocument/") {
            if !self.feature(msg, false, false) {
                self.park(msg)
            }

            return
        }

        if method == "$/cancelRequest" {
            // The editor has moved on: a request still waiting for a snapshot
            // is answered "cancelled" now rather than computed later, and a
            // completion still running is disowned (its worker finishes and
            // is ignored; a process cannot be recalled mid-compile).
            var want = d.dump(d.get(params, "id"))
            var kept: [Parked]
            for var q: usize = 0; q < self.parked.size(); ++q {
                var pd = JsonDoc()
                if pd.parse(self.parked[q].msg) && (pd.dump(pd.get(pd.root, "id")) == want) {
                    self.respond_error(want, -32800, "cancelled")
                } else {
                    kept.push_back(self.parked[q])
                }
            }

            self.parked = kept
            for var q: usize = 0; q < self.jobs.size(); ++q {
                if (self.jobs[q].kind == JOB_COMPLETE()) && (self.jobs[q].id == want) && (!self.jobs[q].cancelled) {
                    self.jobs[q].cancelled = true
                    self.respond_error(want, -32800, "cancelled")
                }
            }

            if (!self.comp_wait_id.empty()) && (self.comp_wait_id == want) {
                self.respond_error(want, -32800, "cancelled")
                self.comp_wait    = ""
                self.comp_wait_id = ""
            }

            return
        }

        if method == "$/kals/text" {
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

        if method.starts_with("$/") || (!has_id) {
            return // progress, and notifications we do not use
        }

        self.respond_error(id, -32601, "method not found: " + method)
    }

    fn initialize(self, d: *const JsonDoc, params: u32, const id: string) {
        var root = d->get_str(params, "rootUri")
        var wf   = d->first(d->get(params, "workspaceFolders"))
        if wf != JSON_NONE() {
            root = d->get_str(wf, "uri")
        }

        if root.empty() {
            var rp = d->get_str(params, "rootPath")
            if !rp.empty() {
                root = path_to_uri(rp)
            }
        }

        if root.empty() {
            self.root = Path::cwd().full_path()
        } else {
            self.root = Path::real_path_of(uri_to_path(root))
        }

        self.project.dir = self.root

        var opts = d->get(params, "initializationOptions")
        var dms  = d->get_int(opts, "debounceMs")
        if d->is_number(d->get(opts, "debounceMs")) && (dms >= 0) && (dms <= 5000) {
            self.debounce_ms = dms
        }

        var sms = d->get_int(opts, "syntaxDebounceMs")
        if d->is_number(d->get(opts, "syntaxDebounceMs")) && (sms >= 0) && (sms <= 5000) {
            self.syntax_ms = sms
        }

        self.progress_ok = d->get_bool(d->get(d->get(params, "capabilities"), "window"), "workDoneProgress")

        var mw = d->get_int(opts, "maxWorkers")
        if d->is_number(d->get(opts, "maxWorkers")) && (mw >= 1) && (mw <= 8) {
            self.max_index = mw as usize
        }

        var ws = d->get(d->get(params, "capabilities"), "workspace")
        self.refresh_tokens = d->get_bool(d->get(ws, "semanticTokens"), "refreshSupport")
        self.refresh_inlays = d->get_bool(d->get(ws, "inlayHint"), "refreshSupport")

        var w = JsonWriter()
        w.begin_object()
        w.key("capabilities")
        w.begin_object()
        // UTF-16 is the encoding every client speaks; none is negotiated.
        w.field("positionEncoding", "utf-16")
        w.key("textDocumentSync")
        w.begin_object()
        w.field_bool("openClose", true)
        w.field_int("change", 2)
        w.field_raw("save", "{\"includeText\":false}")
        w.end_object()
        w.key("semanticTokensProvider")
        w.begin_object()
        w.key("legend")
        w.begin_object()
        w.field_raw("tokenTypes", token_type_names())
        w.field_raw("tokenModifiers", token_modifier_names())
        w.end_object()
        w.field_raw("full", "{\"delta\":true}")
        w.field_bool("range", true)
        w.end_object()
        w.field_bool("definitionProvider", true)
        w.field_bool("hoverProvider", true)
        w.field_bool("documentHighlightProvider", true)
        w.field_bool("referencesProvider", true)
        w.field_raw("renameProvider", "{\"prepareProvider\":true}")
        w.field_bool("typeDefinitionProvider", true)
        w.field_bool("declarationProvider", true)
        w.field_bool("workspaceSymbolProvider", true)
        w.field_bool("foldingRangeProvider", true)
        w.field_bool("selectionRangeProvider", true)
        w.field_raw("documentLinkProvider", "{\"resolveProvider\":false}")
        w.field_raw("signatureHelpProvider", "{\"triggerCharacters\":[\"(\",\",\"]}")
        w.field_bool("implementationProvider", true)
        w.field_bool("callHierarchyProvider", true)
        w.field_bool("typeHierarchyProvider", true)
        w.field_bool("documentRangeFormattingProvider", true)
        w.field_raw("codeLensProvider", "{\"resolveProvider\":false}")
        w.field_bool("documentSymbolProvider", true)
        w.field_bool("documentFormattingProvider", true)
        // The object form, not `true`: both are valid, and a client that
        // only looks for the options object then still sees the capability.
        w.field_raw("inlayHintProvider", "{\"resolveProvider\":false}")
        w.field_raw("codeActionProvider", "{\"codeActionKinds\":[\"quickfix\",\"refactor.inline\"]}")
        w.field_raw("completionProvider", "{\"triggerCharacters\":[\".\",\":\",\">\"],\"resolveProvider\":true}")
        w.field_raw("documentOnTypeFormattingProvider", "{\"firstTriggerCharacter\":\"}\"}")
        w.end_object()
        w.key("serverInfo")
        w.begin_object()
        w.field("name", "kals")
        w.end_object()
        w.end_object()
        self.respond(id, w.out)
    }

    /// The features answered from a snapshot. False: not answerable yet (the
    /// entry is stale or unknown) and \p stale_ok is off, so park it.
    fn feature(self, const msg: string, stale_ok: bool, give_up: bool) -> bool {
        var d = JsonDoc()
        if !d.parse(msg) {
            return true
        }

        var method = d.get_str(d.root, "method")
        var idn    = d.get(d.root, "id")
        if idn == JSON_NONE() {
            return true
        }

        var id     = d.dump(idn)
        var params = d.get(d.root, "params")
        var path   = self.path_of(d.get_str(d.get(params, "textDocument"), "uri"))

        // A buffer that does not parse has no index for its current text,
        // and may not get one until it parses again. Its syntax pass lexed
        // exactly this text: keywords, comments, strings and numbers at
        // their current positions are a correct answer, where the old index
        // would be off by the edits (and ContentModified would leave the
        // editor's colours drifting for as long as the code is broken).
        if method.starts_with("textDocument/semanticTokens/") {
            var ldi = self.docs.index_of_path(path)
            if (ldi != usize::MAX) && self.docs.docs[ldi].syn_landed && (!self.docs.docs[ldi].syn_parsed)
                && (self.docs.docs[ldi].syn_at >= self.docs.docs[ldi].changed_at) {
                var lei = self.entry_of(path)
                var idx_fresh = (lei != usize::MAX) && self.entries[lei].has_idx
                    && (self.entries[lei].idx_rev >= self.docs.docs[ldi].changed_at)
                if !idx_fresh {
                    self.send_tokens(&d, params, id, method, &self.docs.docs[ldi].syn_tokens)
                    return true
                }
            }
        }

        var ei = self.ensure_entry(path)
        if (ei == usize::MAX) || (!self.entries[ei].fresh()) {
            // "Answer from the last snapshot" needs a last snapshot. Until
            // an entry's FIRST index exists there is nothing to answer from,
            // and an empty answer would tell the editor the file has no
            // tokens, no hints and no symbols: wait for it, however slow
            // (wait_first below bounds that).
            var first = (ei != usize::MAX) && (!self.entries[ei].has_idx)
                && (self.entries[ei].running || self.entries[ei].dirty)
            var slow = (ei != usize::MAX) && self.entries[ei].slow && self.entries[ei].has_idx
            if first && (!give_up) {
                return false
            }

            if (!stale_ok) && (!slow) {
                return false
            }

            if ei != usize::MAX {
                self.entries[ei].owe_refresh = true
            }
        }

        var f = JSON_NONE()
        if ei != usize::MAX {
            f = self.file_node(ei, path)
        }

        if (method == "textDocument/codeAction") && (ei != usize::MAX) && self.entries[ei].has_snap {
            // Macro actions carry positions: only from an index of this text.
            var mf = JSON_NONE()
            var mdi = self.docs.index_of_path(path)
            if (f != JSON_NONE()) && ((mdi == usize::MAX) || (self.entries[ei].idx_rev >= self.docs.docs[mdi].changed_at)) {
                mf = f
            }

            self.code_action(&d, params, id, &self.entries[ei].snap, path, ei, mf)
            return true
        }

        if f == JSON_NONE() {
            // No index for this file: it did not parse, or never has. An
            // empty answer, of the shape each method expects.
            if (method == "textDocument/semanticTokens/full") || (method == "textDocument/semanticTokens/full/delta") {
                self.respond(id, "{\"data\":[]}")
            } else if (method == "textDocument/semanticTokens/range") {
                self.respond(id, "{\"data\":[]}")
            } else if (method == "textDocument/hover") || (method == "textDocument/definition")
                || (method == "textDocument/prepareCallHierarchy") || (method == "textDocument/prepareTypeHierarchy")
                || (method == "textDocument/rename") || (method == "textDocument/prepareRename")
                || (method == "textDocument/typeDefinition") || (method == "textDocument/declaration") {
                self.respond(id, "null")
            } else {
                self.respond(id, "[]")
            }

            return true
        }

        // The index may be older than the buffer: the run for this text has
        // not landed, or the text does not parse and the last good index was
        // kept. Its positions are then off by the edits since. Sending them
        // makes the editor draw hints, lenses and colours in the wrong
        // places until the next answer (the flicker). The protocol's answer
        // is ContentModified: the editor keeps what it has, which it has
        // been moving with the text itself, and asks again.
        var di = self.docs.index_of_path(path)
        if (di != usize::MAX) && (self.entries[ei].idx_rev < self.docs.docs[di].changed_at) {
            if (method == "textDocument/hover") || (method == "textDocument/definition")
                || (method == "textDocument/declaration") || (method == "textDocument/typeDefinition")
                || (method == "textDocument/prepareRename") || (method == "textDocument/rename")
                || (method == "textDocument/implementation") || (method == "textDocument/prepareCallHierarchy")
                || (method == "textDocument/prepareTypeHierarchy") {
                // Asked for by hand at a position: no answer beats a wrong one.
                self.respond(id, "null")
            } else if (method == "textDocument/codeAction") {
                self.code_action(&d, params, id, &self.entries[ei].snap, path, ei, JSON_NONE())
            } else {
                self.respond_error(id, -32801, "content modified")
            }

            return true
        }

        var *s   = &self.entries[ei].idx
        var pos  = d.get(params, "position")
        var line = d.get_int(pos, "line")
        var ch   = d.get_int(pos, "character")

        if (method == "textDocument/semanticTokens/full") || (method == "textDocument/semanticTokens/full/delta")
            || (method == "textDocument/semanticTokens/range") {
            var now: [i64]
            var k = self.cache_slot(ei, f)
            if k != usize::MAX {
                now.reserve(self.entries[ei].ct_hi[k] - self.entries[ei].ct_lo[k])
                for var q = self.entries[ei].ct_lo[k]; q < self.entries[ei].ct_hi[k]; ++q {
                    now.push_back(self.entries[ei].ct_data[q])
                }
            }

            self.send_tokens(&d, params, id, method, &now)
            return true
        }

        if method == "textDocument/codeLens" {
            self.code_lens(s, f, path, id)
            return true
        }

        if method == "textDocument/documentSymbol" {
            var w = JsonWriter()
            w.begin_array()
            var c = s->first(s->get(f, "symbols"))
            while c != JSON_NONE() {
                c = self.symbol(s, c, &w)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/inlayHint" {
            self.respond(id, s->dump(s->get(f, "inlays")))
            return true
        }

        if method == "textDocument/codeAction" {
            // Fix-its belong to the CURRENT diagnostics, not to the last
            // run that happened to index.
            self.code_action(&d, params, id, &self.entries[ei].snap, path, ei, f)
            return true
        }

        var row = self.ref_at(ei, f, line, ch)

        if method == "textDocument/hover" {
            // On a macro invocation the question is what it turns into; the
            // names inside it are the expansion's, at the invocation's place.
            var mrow = self.macro_at(s, f, line, ch)
            if mrow != JSON_NONE() {
                var mw = JsonWriter()
                mw.begin_object()
                mw.key("contents")
                mw.begin_object()
                mw.field("kind", "markdown")
                var mtext = s->str(self.nth(s, mrow, 3))
                mw.field("value", "**Expands to**\n\n```kairo\n" + mtext + "\n```")
                mw.end_object()
                mw.key("range")
                mw.begin_object()
                mw.key("start")
                mw.begin_object()
                mw.field_int("line", s->as_int(self.nth(s, mrow, 0)))
                mw.field_int("character", s->as_int(self.nth(s, mrow, 1)))
                mw.end_object()
                mw.key("end")
                mw.begin_object()
                mw.field_int("line", s->as_int(self.nth(s, mrow, 4)))
                mw.field_int("character", s->as_int(self.nth(s, mrow, 5)))
                mw.end_object()
                mw.end_object()
                mw.end_object()
                self.respond(id, mw.out)
                return true
            }

            var h = s->as_int(self.nth(s, row, 7))
            if (row == JSON_NONE()) || (h < 0) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.key("contents")
            w.begin_object()
            w.field("kind", "markdown")
            w.field("value", s->str(self.nth(s, s->get(f, "hovers"), h)))
            w.end_object()
            w.key("range")
            self.write_range(&w, s->as_int(self.nth(s, row, 0)), s->as_int(self.nth(s, row, 1)), s->as_int(self.nth(s, row, 2)))
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        if (method == "textDocument/prepareCallHierarchy") || (method == "textDocument/prepareTypeHierarchy") {
            var fi = s->as_int(self.nth(s, row, 3))
            var k  = s->as_int(self.nth(s, row, 13))
            var is_fn = (k == 11) || (k == 12)
            var is_ty = (k == 2) || (k == 3) || (k == 4) || (k == 5) || (k == 22)
            var call = method == "textDocument/prepareCallHierarchy"
            if (row == JSON_NONE()) || (fi < 0) || (call && (!is_fn)) || ((!call) && (!is_ty)) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_array()
            self.hierarchy_item(
                &w,
                self.name_in_hover(s->str(self.nth(s, s->get(f, "hovers"), s->as_int(self.nth(s, row, 7))))),
                if call => (12 as i64) else => (5 as i64),
                s->str(self.nth(s, s->get(f, "files"), fi)),
                s->as_int(self.nth(s, row, 4)),
                s->as_int(self.nth(s, row, 5)),
                s->as_int(self.nth(s, row, 6)),
            )

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/implementation" {
            // The types that derive or implement the one under the cursor.
            var fi = s->as_int(self.nth(s, row, 3))
            if (row == JSON_NONE()) || (fi < 0) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_array()
            self.related_types(
                s->str(self.nth(s, s->get(f, "files"), fi)),
                s->as_int(self.nth(s, row, 4)),
                s->as_int(self.nth(s, row, 5)),
                false,
                &w,
                false,
            )

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/documentLink" {
            var w = JsonWriter()
            w.begin_array()
            var l = s->first(s->get(f, "links"))
            while l != JSON_NONE() {
                w.begin_object()
                w.key("range")
                self.write_range(&w, s->as_int(self.nth(s, l, 0)), s->as_int(self.nth(s, l, 1)), s->as_int(self.nth(s, l, 2)))
                w.field("target", self.uri_of(s->str(self.nth(s, l, 3))))
                w.end_object()
                l = s->next(l)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/prepareRename" {
            // Only a name the index resolved can be renamed: every one of
            // its uses is then known, and nothing else is.
            if (row == JSON_NONE()) || (s->as_int(self.nth(s, row, 3)) < 0) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            self.write_range(&w, s->as_int(self.nth(s, row, 0)), s->as_int(self.nth(s, row, 1)), s->as_int(self.nth(s, row, 2)))
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/typeDefinition" {
            var ti = s->as_int(self.nth(s, row, 9))
            if (row == JSON_NONE()) || (ti < 0) || (self.nth(s, row, 9) == JSON_NONE()) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.field("uri", self.uri_of(s->str(self.nth(s, s->get(f, "files"), ti))))
            w.key("range")
            self.write_range(&w, s->as_int(self.nth(s, row, 10)), s->as_int(self.nth(s, row, 11)), s->as_int(self.nth(s, row, 12)))
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        if (method == "textDocument/definition") || (method == "textDocument/declaration") {
            var fi = s->as_int(self.nth(s, row, 3))
            if (row == JSON_NONE()) || (fi < 0) {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.field("uri", self.uri_of(s->str(self.nth(s, s->get(f, "files"), fi))))
            w.key("range")
            self.write_range(&w, s->as_int(self.nth(s, row, 4)), s->as_int(self.nth(s, row, 5)), s->as_int(self.nth(s, row, 6)))
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/documentHighlight" {
            var w = JsonWriter()
            w.begin_array()
            if row != JSON_NONE() {
                self.uses(s, f, row, &w, 1, path, "", true)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/references" {
            var with_decl = d.get_bool(d.get(params, "context"), "includeDeclaration")
            var w = JsonWriter()
            w.begin_array()
            if row != JSON_NONE() {
                self.uses(s, f, row, &w, 0, "", "", with_decl)
            }

            w.end_array()
            self.respond(id, w.out)
            return true
        }

        if method == "textDocument/rename" {
            if row == JSON_NONE() {
                self.respond(id, "null")
                return true
            }

            var w = JsonWriter()
            w.begin_object()
            w.key("changes")
            w.begin_object()
            self.uses(s, f, row, &w, 2, "", d.get_str(params, "newName"), true)
            w.end_object()
            w.end_object()
            self.respond(id, w.out)
            return true
        }

        self.respond_error(id, -32601, "method not found: " + method)
        return true
    }

    /// Answers a semanticTokens request (full, delta or range) from \p now,
    /// the five-integer encoding of the whole file: the index's (decoded once
    /// per snapshot), or the lexical tokens of a buffer that does not parse.
    fn send_tokens(self, d: *const JsonDoc, params: u32, const id: string, const method: string, now: *const [i64]) {
        if method == "textDocument/semanticTokens/range" {
            // Cut to the lines asked for and re-based: the encoding is
            // relative, so the first one kept restarts it.
            var rr = d->get(params, "range")
            var lo = d->get_int(d->get(rr, "start"), "line")
            var hi = d->get_int(d->get(rr, "end"), "line")
            var w = JsonWriter()
            w.begin_object()
            w.key("data")
            w.begin_array()
            var tl: i64 = 0
            var tc: i64 = 0
            var pl: i64 = 0
            var pc: i64 = 0
            var t: usize = 0
            while (t + 5) <= now->size() {
                var dl = (*now)[t]
                var dc = (*now)[t + 1]
                if dl != 0 {
                    tl += dl
                    tc = dc
                } else {
                    tc += dc
                }

                if tl > hi {
                    break
                }

                if tl >= lo {
                    w.integer(tl - pl)
                    w.integer(if tl == pl => (tc - pc) else => tc)
                    w.integer((*now)[t + 2])
                    w.integer((*now)[t + 3])
                    w.integer((*now)[t + 4])
                    pl = tl
                    pc = tc
                }

                t += 5
            }

            w.end_array()
            w.end_object()
            self.respond(id, w.out)
            return
        }

        var uri = d->get_str(d->get(params, "textDocument"), "uri")
        var slot = self.tok_uri.size()
        for var q: usize = 0; q < self.tok_uri.size(); ++q {
            if self.tok_uri[q] == uri {
                slot = q
            }
        }

        if slot == self.tok_uri.size() {
            self.tok_uri.push_back(uri)
            self.tok_id.push_back(0)
            var none: [i64]
            self.tok_data.push_back(none)
        }

        self.tok_seq += 1
        var rid  = self.tok_seq
        var prev = d->get_str(params, "previousResultId")
        var have = f"{self.tok_id[slot]}"
        var w = JsonWriter()
        w.begin_object()
        w.field("resultId", f"{rid}")
        if (method == "textDocument/semanticTokens/full/delta") && (prev == have) && (self.tok_id[slot] != 0) {
            // One edit: what lies between the longest common prefix and
            // suffix of the two integer arrays. Cut on token boundaries
            // (multiples of five) so a relative position is never split.
            var *old = &self.tok_data[slot]
            var a: usize = 0
            while (a < old->size()) && (a < now->size()) && ((*old)[a] == (*now)[a]) {
                a += 1
            }

            a = (a / 5) * 5
            var oe = old->size()
            var ne = now->size()
            while (oe > a) && (ne > a) && ((*old)[oe - 1] == (*now)[ne - 1]) {
                oe -= 1
                ne -= 1
            }

            while ((oe % 5) != 0) && (oe < old->size()) {
                oe += 1
                ne += 1
            }

            w.key("edits")
            w.begin_array()
            if (oe > a) || (ne > a) {
                w.begin_object()
                w.field_uint("start", a)
                w.field_uint("deleteCount", oe - a)
                w.key("data")
                w.begin_array()
                for var q: usize = a; q < ne; ++q {
                    w.integer((*now)[q])
                }

                w.end_array()
                w.end_object()
            }

            w.end_array()
        } else {
            w.key("data")
            w.begin_array()
            for var q: usize = 0; q < now->size(); ++q {
                w.integer((*now)[q])
            }

            w.end_array()
        }

        w.end_object()
        self.tok_id[slot]   = rid
        self.tok_data[slot] = *now
        self.respond(id, w.out)
    }

    /// Writes symbol \p c with the symbols its range contains as children.
    /// Returns the next symbol that is NOT inside it. The snapshot lists
    /// symbols flat in source order, a parent before its members.
    fn symbol(self, s: *const JsonDoc, c: u32, w: *JsonWriter) -> u32 {
        var range = s->get(c, "range")
        var end   = s->get(range, "end")
        var el    = s->get_int(end, "line")
        var ec    = s->get_int(end, "character")

        w->begin_object()
        w->field("name", s->get_str(c, "name"))
        var detail = s->get_str(c, "detail")
        if !detail.empty() {
            w->field("detail", detail)
        }

        w->field_int("kind", s->get_int(c, "kind"))
        w->field_raw("range", s->dump(range))
        w->field_raw("selectionRange", s->dump(s->get(c, "selectionRange")))
        w->key("children")
        w->begin_array()
        var n = s->next(c)
        while n != JSON_NONE() {
            var st = s->get(s->get(n, "range"), "start")
            var sl = s->get_int(st, "line")
            var sc = s->get_int(st, "character")
            if (sl > el) || ((sl == el) && (sc >= ec)) {
                break
            }

            n = self.symbol(s, n, w)
        }

        w->end_array()
        w->end_object()
        return n
    }

    /// Quick fixes: the compiler's fix-its for the diagnostics the requested
    /// range touches, each as an edit the editor applies.
    fn code_action(self,
                   d:          *const JsonDoc,
                   params:     u32,
                   const id:   string,
                   s:          *const JsonDoc,
                   const path: string,
                   ei:         usize,
                   mf:         u32) {
        var rr = d->get(params, "range")
        var rs = d->get_int(d->get(rr, "start"), "line")
        var re = d->get_int(d->get(rr, "end"), "line")

        var w = JsonWriter()
        w.begin_array()
        var x = s->first(s->get(s->root, "diagnostics"))
        while x != JSON_NONE() {
            var diag = s->get(x, "diag")
            var dr   = s->get(diag, "range")
            var ds   = s->get_int(s->get(dr, "start"), "line")
            var de   = s->get_int(s->get(dr, "end"), "line")
            if (s->get_str(x, "path") == path) && (ds <= re) && (de >= rs) {
                var fix = s->first(s->get(x, "fixes"))
                var first = true
                while fix != JSON_NONE() {
                    w.begin_object()
                    w.field("title", s->get_str(fix, "title"))
                    w.field("kind", "quickfix")
                    w.field_raw("diagnostics", "[" + s->dump(diag) + "]")
                    // The compiler lists its preferred fix first.
                    w.field_bool("isPreferred", first)
                    first = false
                    w.key("edit")
                    w.begin_object()
                    w.key("changes")
                    w.begin_object()
                    var e = s->first(s->get(fix, "edits"))
                    while e != JSON_NONE() {
                        w.key(self.uri_of(s->get_str(e, "path")))
                        w.begin_array()
                        w.begin_object()
                        w.field_raw("range", s->dump(s->get(e, "range")))
                        w.field("newText", s->get_str(e, "newText"))
                        w.end_object()
                        w.end_array()
                        e = s->next(e)
                    }

                    w.end_object()
                    w.end_object()
                    w.end_object()
                    fix = s->next(fix)
                }
            }

            x = s->next(x)
        }

        // On a macro invocation: show what it expands to beside the editor
        // (a command the kairo-lsp clients implement), or replace it with
        // that text (an edit: works in any client).
        if (mf != JSON_NONE()) && (ei < self.entries.size()) && self.entries[ei].has_idx {
            var *xs = &self.entries[ei].idx
            var cs = d->get_int(d->get(rr, "start"), "character")
            var ce = d->get_int(d->get(rr, "end"), "character")
            var uri = self.uri_of(path)
            var m = xs->first(xs->get(mf, "macros"))
            while m != JSON_NONE() {
                var ml = xs->as_int(self.nth(xs, m, 0))
                var mc = xs->as_int(self.nth(xs, m, 1))
                var el = xs->as_int(self.nth(xs, m, 4))
                var ec = xs->as_int(self.nth(xs, m, 5))
                // the request range [rs:cs, re:ce] touches [ml:mc, el:ec]
                var before = (re < ml) || ((re == ml) && (ce < mc))
                var after  = (rs > el) || ((rs == el) && (cs > ec))
                if (!before) && (!after) {
                    var text = xs->str(self.nth(xs, m, 3))
                    var rw = JsonWriter()
                    rw.begin_object()
                    rw.key("start")
                    rw.begin_object()
                    rw.field_int("line", ml)
                    rw.field_int("character", mc)
                    rw.end_object()
                    rw.key("end")
                    rw.begin_object()
                    rw.field_int("line", el)
                    rw.field_int("character", ec)
                    rw.end_object()
                    rw.end_object()

                    w.begin_object()
                    w.field("title", "View expanded macro")
                    w.field("kind", "quickfix")
                    w.key("command")
                    w.begin_object()
                    w.field("title", "View expanded macro")
                    w.field("command", "kairo.showMacroExpansion")
                    w.key("arguments")
                    w.begin_array()
                    w.str(uri)
                    w.raw(rw.out)
                    w.str(text)
                    w.end_array()
                    w.end_object()
                    w.end_object()

                    w.begin_object()
                    w.field("title", "Expand macro here")
                    w.field("kind", "refactor.inline")
                    w.key("edit")
                    w.begin_object()
                    w.key("changes")
                    w.begin_object()
                    w.key(uri)
                    w.begin_array()
                    w.begin_object()
                    w.field_raw("range", rw.out)
                    w.field("newText", text)
                    w.end_object()
                    w.end_array()
                    w.end_object()
                    w.end_object()
                    w.end_object()
                }

                m = xs->next(m)
            }
        }

        w.end_array()
        self.respond(id, w.out)
    }

    /// The macro row of file node \p f (in \p s) whose invocation holds
    /// (line, ch), or JSON_NONE.
    fn macro_at(const self, s: *const JsonDoc, f: u32, line: i64, ch: i64) -> u32 {
        var m = s->first(s->get(f, "macros"))
        while m != JSON_NONE() {
            var ml = s->as_int(self.nth(s, m, 0))
            var mc = s->as_int(self.nth(s, m, 1))
            var el = s->as_int(self.nth(s, m, 4))
            var ec = s->as_int(self.nth(s, m, 5))
            var after_start = (line > ml) || ((line == ml) && (ch >= mc))
            var before_end  = (line < el) || ((line == el) && (ch <= ec))
            if after_start && before_end {
                return m
            }

            m = s->next(m)
        }

        return JSON_NONE()
    }

    // --- hierarchies ------------------------------------------------------

    /// The declared name inside a hover's code line: `fn NAME(`, `class NAME`.
    fn name_in_hover(const self, const md: string) -> string {
        var ls: usize = 9 // past "```kairo\n"
        if md.size() <= ls {
            return "?"
        }

        var le = ls
        while (le < md.size()) && (md[le] != 10) {
            le += 1
        }

        var line = md.subslice(ls, le - ls)
        // A type's hover opens its body on the same line: `class Box {`.
        var brace = find_from(line, " {", 0)
        if brace != usize::MAX {
            line = line.subslice(0, brace)
        }

        // the word before `(`, or the last word of the line
        var stop = find_from(line, "(", 0)
        if (stop == usize::MAX) || line.starts_with("(") {
            stop = line.size()
            var colon = find_from(line, ":", 0)
            if colon != usize::MAX {
                stop = colon
            }
        }

        var b = stop
        while (b > 0) && (line[b - 1] != 32) {
            b -= 1
        }

        if stop <= b {
            return line
        }

        return line.subslice(b, stop - b)
    }

    /// A CallHierarchyItem / TypeHierarchyItem: both have this shape.
    fn hierarchy_item(self,
                      w:           *JsonWriter,
                      const name:  string,
                      kind:        i64,
                      const path:  string,
                      line:        i64,
                      ch:          i64,
                      len:         i64) {
        w->begin_object()
        w->field("name", name)
        w->field_int("kind", kind)
        w->field("uri", self.uri_of(path))
        w->key("range")
        self.write_range(w, line, ch, len)
        w->key("selectionRange")
        self.write_range(w, line, ch, len)
        w->end_object()
    }

    /// The function symbol of file node \p f whose body holds (line, ch).
    fn enclosing_fn(const self, s: *const JsonDoc, f: u32, line: i64, ch: i64) -> u32 {
        var best = JSON_NONE()
        var c = s->first(s->get(f, "symbols"))
        while c != JSON_NONE() {
            var k = s->get_int(c, "kind")
            if (k == 12) || (k == 6) {
                var r  = s->get(c, "range")
                var st = s->get(r, "start")
                var en = s->get(r, "end")
                var sl = s->get_int(st, "line")
                var el = s->get_int(en, "line")
                var after  = (line > sl) || ((line == sl) && (ch >= s->get_int(st, "character")))
                var before = (line < el) || ((line == el) && (ch <= s->get_int(en, "character")))
                if after && before {
                    best = c // source order: a later match is nested deeper
                }
            }

            c = s->next(c)
        }

        return best
    }

    /// Incoming or outgoing calls of the function \p item names.
    fn calls(self, d: *const JsonDoc, item: u32, incoming: bool, const id: string) {
        var path = self.path_of(d->get_str(item, "uri"))
        var sel  = d->get(d->get(item, "selectionRange"), "start")
        var line = d->get_int(sel, "line")
        var ch   = d->get_int(sel, "character")

        // Results are grouped by the function on the other end; `keys` holds
        // one entry per group, the parallel vectors its parts.
        var keys:   [string]
        var heads:  [string] // the item JSON
        var ranges: [string] // comma-joined fromRanges

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, "path")
                if (!incoming) && (fpath != path) {
                    of = o->next(of)
                    continue
                }

                // Outgoing: the body is the symbol whose name is the item.
                var body = JSON_NONE()
                if !incoming {
                    var c = o->first(o->get(of, "symbols"))
                    while c != JSON_NONE() {
                        var ss = o->get(o->get(c, "selectionRange"), "start")
                        if (o->get_int(ss, "line") == line) && (o->get_int(ss, "character") == ch) {
                            body = c
                        }

                        c = o->next(c)
                    }

                    if body == JSON_NONE() {
                        of = o->next(of)
                        continue
                    }
                }

                var r = o->first(o->get(of, "refs"))
                while r != JSON_NONE() {
                    var fi   = o->as_int(self.nth(o, r, 3))
                    var kind = o->as_int(self.nth(o, r, 13))
                    var rl   = o->as_int(self.nth(o, r, 0))
                    var rc   = o->as_int(self.nth(o, r, 1))
                    var use  = (fi >= 0) && (o->as_int(self.nth(o, r, 8)) == 0) && ((kind == 11) || (kind == 12))
                    if !use {
                        r = o->next(r)
                        continue
                    }

                    var dpath = o->str(self.nth(o, o->get(of, "files"), fi))
                    var dl    = o->as_int(self.nth(o, r, 4))
                    var dc    = o->as_int(self.nth(o, r, 5))

                    var key:  string = ""
                    var head = JsonWriter()
                    if incoming {
                        if (dpath != path) || (dl != line) || (dc != ch) {
                            r = o->next(r)
                            continue
                        }

                        var from = self.enclosing_fn(o, of, rl, rc)
                        if from == JSON_NONE() {
                            r = o->next(r)
                            continue
                        }

                        var fs = o->get(o->get(from, "selectionRange"), "start")
                        var fe = o->get(o->get(from, "selectionRange"), "end")
                        key = fpath + ":" + o->dump(fs)
                        self.hierarchy_item(
                            &head,
                            o->get_str(from, "name"),
                            12,
                            fpath,
                            o->get_int(fs, "line"),
                            o->get_int(fs, "character"),
                            o->get_int(fe, "character") - o->get_int(fs, "character"),
                        )
                    } else {
                        var inside = self.enclosing_fn(o, of, rl, rc)
                        if inside != body {
                            r = o->next(r)
                            continue
                        }

                        key = f"{dpath}:{dl}:{dc}"
                        self.hierarchy_item(
                            &head,
                            self.name_in_hover(o->str(self.nth(o, o->get(of, "hovers"), o->as_int(self.nth(o, r, 7))))),
                            12,
                            dpath,
                            dl,
                            dc,
                            o->as_int(self.nth(o, r, 6)),
                        )
                    }

                    var rw = JsonWriter()
                    self.write_range(&rw, rl, rc, o->as_int(self.nth(o, r, 2)))
                    var g = keys.size()
                    for var q: usize = 0; q < keys.size(); ++q {
                        if keys[q] == key {
                            g = q
                        }
                    }

                    if g == keys.size() {
                        keys.push_back(key)
                        heads.push_back(head.out)
                        ranges.push_back(rw.out)
                    } else if find_from(ranges[g], rw.out, 0) == usize::MAX {
                        ranges[g] = ranges[g] + "," + rw.out
                    }

                    r = o->next(r)
                }

                of = o->next(of)
            }
        }

        var w = JsonWriter()
        w.begin_array()
        for var g: usize = 0; g < keys.size(); ++g {
            w.begin_object()
            w.field_raw(if incoming => "from" else => "to", heads[g])
            w.field_raw("fromRanges", "[" + ranges[g] + "]")
            w.end_object()
        }

        w.end_array()
        self.respond(id, w.out)
    }

    /// Types one edge from the declaration at (path, line, ch): what it
    /// derives (\p up) or what derives it. As hierarchy items, or as plain
    /// Locations for "go to implementation".
    fn related_types(self, const path: string, line: i64, ch: i64, up: bool, w: *JsonWriter, items: bool) {
        var seen: [string]
        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, "path")
                var b = o->first(o->get(of, "bases"))
                while b != JSON_NONE() {
                    var bpath = o->str(self.nth(o, o->get(of, "files"), o->as_int(self.nth(o, b, 3))))
                    var dl = o->as_int(self.nth(o, b, 0))
                    var dc = o->as_int(self.nth(o, b, 1))
                    var bl = o->as_int(self.nth(o, b, 4))
                    var bc = o->as_int(self.nth(o, b, 5))

                    var hit = false
                    var rp: string = ""
                    var rl: i64 = 0
                    var rc: i64 = 0
                    var rn: i64 = 0
                    var name: string = ""
                    var kind: i64 = 5
                    if up && (fpath == path) && (dl == line) && (dc == ch) {
                        hit  = true
                        rp   = bpath
                        rl   = bl
                        rc   = bc
                        rn   = o->as_int(self.nth(o, b, 6))
                        name = o->str(self.nth(o, b, 8))
                        kind = o->as_int(self.nth(o, b, 10))
                    } else if (!up) && (bpath == path) && (bl == line) && (bc == ch) {
                        hit  = true
                        rp   = fpath
                        rl   = dl
                        rc   = dc
                        rn   = o->as_int(self.nth(o, b, 2))
                        name = o->str(self.nth(o, b, 7))
                        kind = o->as_int(self.nth(o, b, 9))
                    }

                    if hit {
                        var key = f"{rp}:{rl}:{rc}"
                        var dup = false
                        for var q: usize = 0; q < seen.size(); ++q {
                            if seen[q] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            if items {
                                self.hierarchy_item(w, name, kind, rp, rl, rc, rn)
                            } else {
                                w->begin_object()
                                w->field("uri", self.uri_of(rp))
                                w->key("range")
                                self.write_range(w, rl, rc, rn)
                                w->end_object()
                            }
                        }
                    }

                    b = o->next(b)
                }

                of = o->next(of)
            }
        }
    }

    /// "N references" above each function and type of the file.
    fn code_lens(self, s: *const JsonDoc, f: u32, const path: string, const id: string) {
        // One pass over every snapshot's refs, counting uses per declaration
        // of THIS file; a use is counted once however many entries index it.
        var decl_keys: [string]
        var counts:    [usize]
        var sites:     [string]
        var c = s->first(s->get(f, "symbols"))
        while c != JSON_NONE() {
            var ss = s->get(s->get(c, "selectionRange"), "start")
            decl_keys.push_back(s->dump(ss))
            counts.push_back(0)
            sites.push_back("")
            c = s->next(c)
        }

        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var fpath = o->get_str(of, "path")
                var r = o->first(o->get(of, "refs"))
                while r != JSON_NONE() {
                    var fi = o->as_int(self.nth(o, r, 3))
                    if (fi >= 0) && (o->as_int(self.nth(o, r, 8)) == 0)
                        && (o->str(self.nth(o, o->get(of, "files"), fi)) == path) {
                        var dl = o->as_int(self.nth(o, r, 4))
                        var dc = o->as_int(self.nth(o, r, 5))
                        var key  = "{\"line\":" + f"{dl}" + ",\"character\":" + f"{dc}" + "}"
                        var site = fpath + ":" + f"{o->as_int(self.nth(o, r, 0))}" + ":" + f"{o->as_int(self.nth(o, r, 1))}" + ";"
                        for var k: usize = 0; k < decl_keys.size(); ++k {
                            if (decl_keys[k] == key) && (find_from(sites[k], site, 0) == usize::MAX) {
                                sites[k] += site
                                counts[k] += 1
                            }
                        }
                    }

                    r = o->next(r)
                }

                of = o->next(of)
            }
        }

        var w = JsonWriter()
        w.begin_array()
        var k: usize = 0
        c = s->first(s->get(f, "symbols"))
        while c != JSON_NONE() {
            var kind = s->get_int(c, "kind")
            var wanted = (kind == 12) || (kind == 6) || (kind == 5) || (kind == 23) || (kind == 11) || (kind == 10)
            if wanted {
                w.begin_object()
                w.field_raw("range", s->dump(s->get(c, "selectionRange")))
                w.key("command")
                w.begin_object()
                var n = counts[k]
                w.field("title", if n == 1 => "1 reference" else => (f"{n}" + " references"))
                // No command id: the lens is information. An editor that
                // wants a click wires its own "show references" to it.
                w.field("command", "")
                w.end_object()
                w.end_object()
            }

            k += 1
            c = s->next(c)
        }

        w.end_array()
        self.respond(id, w.out)
    }

    // --- answered from the text -------------------------------------------

    /// Writes `{"line":L,"character":C}` for byte \p off of buffer \p i.
    fn write_pos(self, w: *JsonWriter, i: usize, off: usize) {
        w->begin_object()
        w->field_uint("line", self.docs.docs[i].lines.line_of(off))
        w->field_uint("character", self.docs.docs[i].lines.character(self.docs.docs[i].text, off, false))
        w->end_object()
    }

    fn folding(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "[]")
            return
        }

        var sp = spans(self.docs.docs[i].text)
        var w = JsonWriter()
        w.begin_array()
        for var k: usize = 0; k < sp.size(); ++k {
            if sp[k].close == usize::MAX {
                continue
            }

            var a = self.docs.docs[i].lines.line_of(sp[k].open)
            var b = self.docs.docs[i].lines.line_of(sp[k].close)
            if sp[k].kind == 3 {
                // The run's end is one past its last byte.
                b = self.docs.docs[i].lines.line_of(sp[k].close - 1)
            } else if b > a {
                b -= 1 // keep the closing bracket's line visible
            }

            if b <= a {
                continue
            }

            w.begin_object()
            w.field_uint("startLine", a)
            w.field_uint("endLine", b)
            if sp[k].kind == 3 {
                w.field("kind", "comment")
            }

            w.end_object()
        }

        w.end_array()
        self.respond(id, w.out)
    }

    fn selection(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "[]")
            return
        }

        var *text = &self.docs.docs[i].text
        var sp = spans(*text)
        var w = JsonWriter()
        w.begin_array()
        var p = d->first(d->get(params, "positions"))
        while p != JSON_NONE() {
            var at = self.docs.docs[i].lines.offset(
                *text,
                d->get_int(p, "line") as usize,
                d->get_int(p, "character") as usize,
                false,
            )

            // Innermost first: the word, then each bracket's inside and
            // outside, then the file. Each is the "parent" of the one before.
            var los: [usize]
            var his: [usize]
            var ws = at
            while (ws > 0) && is_ident_byte((*text)[ws - 1]) {
                ws -= 1
            }

            var we = at
            while (we < text->size()) && is_ident_byte((*text)[we]) {
                we += 1
            }

            if we > ws {
                los.push_back(ws)
                his.push_back(we)
            }

            var k = sp.size()
            while k > 0 {
                k -= 1
                if (sp[k].kind == 3) || (sp[k].close == usize::MAX) {
                    continue
                }

                if (sp[k].open < at) && (at <= sp[k].close) {
                    los.push_back(sp[k].open + 1)
                    his.push_back(sp[k].close)
                    los.push_back(sp[k].open)
                    his.push_back(sp[k].close + 1)
                }
            }

            los.push_back(0)
            his.push_back(text->size())

            // A parent must contain its child; drop any range that does not
            // strictly grow, then nest from the outside in.
            var keep_lo: [usize]
            var keep_hi: [usize]
            for var q: usize = 0; q < los.size(); ++q {
                if keep_lo.empty() {
                    keep_lo.push_back(los[q])
                    keep_hi.push_back(his[q])
                    continue
                }

                var pl = keep_lo[keep_lo.size() - 1]
                var ph = keep_hi[keep_hi.size() - 1]
                if (los[q] <= pl) && (his[q] >= ph) && ((los[q] < pl) || (his[q] > ph)) {
                    keep_lo.push_back(los[q])
                    keep_hi.push_back(his[q])
                }
            }

            for var q: usize = 0; q < keep_lo.size(); ++q {
                w.begin_object()
                w.key("range")
                w.begin_object()
                w.key("start")
                self.write_pos(&w, i, keep_lo[q])
                w.key("end")
                self.write_pos(&w, i, keep_hi[q])
                w.end_object()
                if (q + 1) < keep_lo.size() {
                    w.key("parent")
                }
            }

            for var q: usize = 0; q < keep_lo.size(); ++q {
                w.end_object()
            }

            p = d->next(p)
        }

        w.end_array()
        self.respond(id, w.out)
    }

    /// The signatures of the function whose argument list the cursor is in.
    ///
    /// The call is found in the text (it is usually half typed, so no
    /// snapshot has it); its name is then looked up among the declarations
    /// the snapshots have hover text for. Every `fn name(` found is offered,
    /// which is exactly the overload set a reader wants to see.
    fn signature_help(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "null")
            return
        }

        var *text = &self.docs.docs[i].text
        var pos = d->get(params, "position")
        var at = self.docs.docs[i].lines.offset(
            *text,
            d->get_int(pos, "line") as usize,
            d->get_int(pos, "character") as usize,
            false,
        )

        var site = call_at(*text, at)
        if site.open == usize::MAX {
            self.respond(id, "null")
            return
        }

        var e = site.open
        while (e > 0) && (((*text)[e - 1] == 32) || ((*text)[e - 1] == 9)) {
            e -= 1
        }

        var b = e
        while (b > 0) && is_ident_byte((*text)[b - 1]) {
            b -= 1
        }

        if b == e {
            self.respond(id, "null")
            return
        }

        var name   = text->subslice(b, e - b)
        var prefix = "```kairo\nfn " + name + "("

        var labels: [string]
        var docs:   [string]
        for var ei: usize = 0; ei < self.entries.size(); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while of != JSON_NONE() {
                var h = o->first(o->get(of, "hovers"))
                while h != JSON_NONE() {
                    var md = o->str(h)
                    if md.starts_with(prefix) {
                        // The signature is the code block's one line.
                        var ls: usize = 9
                        var le = ls
                        while (le < md.size()) && (md[le] != 10) {
                            le += 1
                        }

                        var label = md.subslice(ls, le - ls)
                        var cut = find_from(label, "  //", 0)
                        if cut != usize::MAX {
                            label = label.subslice(0, cut)
                        }

                        var dup = false
                        for var q: usize = 0; q < labels.size(); ++q {
                            if labels[q] == label {
                                dup = true
                            }
                        }

                        if !dup {
                            labels.push_back(label)
                            var sep = find_from(md, "\n---\n\n", 0)
                            if sep != usize::MAX {
                                docs.push_back(md.subslice(sep + 6, md.size() - sep - 6))
                            } else {
                                docs.push_back("")
                            }
                        }
                    }

                    h = o->next(h)
                }

                of = o->next(of)
            }
        }

        if labels.empty() {
            // No snapshot has seen this function declared or used (it is
            // being called for the first time). Its declaration is still in
            // some file the entry reads: find `fn name(` in their text.
            var ei = self.entry_of(self.docs.docs[i].path)
            if ei != usize::MAX {
                var needle = "fn " + name + "("
                for var fidx: usize = 0; (fidx < self.entries[ei].files.size()) && (labels.size() < 8); ++fidx {
                    var src: string = ""
                    var di = self.docs.index_of_path(self.entries[ei].files[fidx])
                    if di != usize::MAX {
                        src = self.docs.docs[di].text
                    } else if !LinkFS::read(self.entries[ei].files[fidx], &src) {
                        continue
                    }

                    var from: usize = 0
                    while labels.size() < 8 {
                        var hit = find_from(src, needle, from)
                        if hit == usize::MAX {
                            break
                        }

                        from = hit + needle.size()
                        // The signature runs to the body, an `=`, a `where`
                        // / `requires` clause, or the end of the line.
                        var e2 = hit
                        var depth: usize = 0
                        while e2 < src.size() {
                            var ch = src[e2]
                            if ch == 40 {
                                depth += 1
                            } else if (ch == 41) && (depth > 0) {
                                depth -= 1
                            } else if (depth == 0) && ((ch == 123) || (ch == 10) || (ch == 61)) {
                                break
                            }

                            e2 += 1
                        }

                        var label = src.subslice(hit, e2 - hit)
                        var cut = find_from(label, " where ", 0)
                        if cut == usize::MAX {
                            cut = find_from(label, " requires ", 0)
                        }

                        if cut != usize::MAX {
                            label = label.subslice(0, cut)
                        }

                        while (label.size() > 0) && (label[label.size() - 1] == 32) {
                            label = label.subslice(0, label.size() - 1)
                        }

                        var dup = false
                        for var q: usize = 0; q < labels.size(); ++q {
                            if labels[q] == label {
                                dup = true
                            }
                        }

                        if !dup {
                            labels.push_back(label)
                            docs.push_back("")
                        }
                    }
                }
            }
        }

        if labels.empty() {
            self.respond(id, "null")
            return
        }

        var active_sig: usize = 0
        var picked = false
        var w = JsonWriter()
        w.begin_object()
        w.key("signatures")
        w.begin_array()
        for var q: usize = 0; q < labels.size(); ++q {
            w.begin_object()
            w.field("label", labels[q])
            if !docs[q].empty() {
                w.key("documentation")
                w.begin_object()
                w.field("kind", "markdown")
                w.field("value", docs[q])
                w.end_object()
            }

            // Parameters as [start, end) offsets into the label: the text
            // between the outer parentheses, split at top-level commas. A
            // leading `self` is not something the caller writes.
            w.key("parameters")
            w.begin_array()
            var lp = find_from(labels[q], "(", 0)
            var count: usize = 0
            if lp != usize::MAX {
                var depth: usize = 0
                var start = lp + 1
                for var c: usize = lp + 1; c < labels[q].size(); ++c {
                    var ch = labels[q][c]
                    if (ch == 40) || (ch == 91) || (ch == 60) {
                        depth += 1
                    } else if ((ch == 41) || (ch == 93) || (ch == 62)) && (depth > 0) {
                        // `->` is not a closing angle bracket.
                        if !((ch == 62) && (c > 0) && (labels[q][c - 1] == 45)) {
                            depth -= 1
                        }
                    } else if ((ch == 44) || (ch == 41)) && (depth == 0) {
                        var ps = start
                        while (ps < c) && (labels[q][ps] == 32) {
                            ps += 1
                        }

                        var piece = labels[q].subslice(ps, c - ps)
                        if (c > ps) && (piece != "self") && (piece != "const self") {
                            w.begin_object()
                            w.key("label")
                            w.begin_array()
                            w.uint(ps)
                            w.uint(c)
                            w.end_array()
                            w.end_object()
                            count += 1
                        }

                        start = c + 1
                        if ch == 41 {
                            break
                        }
                    }
                }
            }

            w.end_array()
            w.end_object()

            // The first overload with room for the argument being typed.
            if (!picked) && (count > site.commas) {
                active_sig = q
                picked     = true
            }
        }

        w.end_array()
        w.field_uint("activeSignature", active_sig)
        w.field_uint("activeParameter", site.commas)
        w.end_object()
        self.respond(id, w.out)
    }

    /// A `}` was typed: put it in the column of the line that opened its
    /// block. The one on-type edit that is unambiguous from the text alone.
    fn on_type(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if (i == usize::MAX) || (d->get_str(params, "ch") != "}") {
            self.respond(id, "[]")
            return
        }

        var *text = &self.docs.docs[i].text
        var pos = d->get(params, "position")
        var at = self.docs.docs[i].lines.offset(
            *text,
            d->get_int(pos, "line") as usize,
            d->get_int(pos, "character") as usize,
            false,
        )

        if (at == 0) || ((*text)[at - 1] != 125) {
            self.respond(id, "[]")
            return
        }

        var close = at - 1
        var ls = self.docs.docs[i].lines.starts[self.docs.docs[i].lines.line_of(close)]
        // Only when the brace is the first thing on its line.
        for var p: usize = ls; p < close; ++p {
            if ((*text)[p] != 32) && ((*text)[p] != 9) {
                self.respond(id, "[]")
                return
            }
        }

        var sp = spans(*text)
        var open = usize::MAX
        for var k: usize = 0; k < sp.size(); ++k {
            if (sp[k].kind == 0) && (sp[k].close == close) {
                open = sp[k].open
            }
        }

        if open == usize::MAX {
            self.respond(id, "[]")
            return
        }

        var os = self.docs.docs[i].lines.starts[self.docs.docs[i].lines.line_of(open)]
        var oe = os
        while (oe < text->size()) && (((*text)[oe] == 32) || ((*text)[oe] == 9)) {
            oe += 1
        }

        var want = text->subslice(os, oe - os)
        if want == text->subslice(ls, close - ls) {
            self.respond(id, "[]")
            return
        }

        var w = JsonWriter()
        w.begin_array()
        w.begin_object()
        w.key("range")
        w.begin_object()
        w.key("start")
        self.write_pos(&w, i, ls)
        w.key("end")
        self.write_pos(&w, i, close)
        w.end_object()
        w.field("newText", want)
        w.end_object()
        w.end_array()
        self.respond(id, w.out)
    }

    /// Declarations whose name contains \p query, across every snapshot.
    fn workspace_symbols(self, const query: string, const id: string) {
        var needle = lower(query)
        var seen: [string]
        var w = JsonWriter()
        w.begin_array()
        var total: usize = 0
        for var ei: usize = 0; (ei < self.entries.size()) && (total < 512); ++ei {
            if !self.entries[ei].has_idx {
                continue
            }

            var *o = &self.entries[ei].idx
            var of = o->first(o->get(o->root, "files"))
            while (of != JSON_NONE()) && (total < 512) {
                var path = o->get_str(of, "path")
                var sy = o->first(o->get(of, "symbols"))
                while (sy != JSON_NONE()) && (total < 512) {
                    var name = o->get_str(sy, "name")
                    if needle.empty() || (find_from(lower(name), needle, 0) != usize::MAX) {
                        var range = o->dump(o->get(sy, "selectionRange"))
                        var key = path + range
                        var dup = false
                        for var q: usize = 0; q < seen.size(); ++q {
                            if seen[q] == key {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(key)
                            w.begin_object()
                            w.field("name", name)
                            w.field_int("kind", o->get_int(sy, "kind"))
                            w.key("location")
                            w.begin_object()
                            w.field("uri", self.uri_of(path))
                            w.field_raw("range", range)
                            w.end_object()
                            w.end_object()
                            total += 1
                        }
                    }

                    sy = o->next(sy)
                }

                of = o->next(of)
            }
        }

        w.end_array()
        self.respond(id, w.out)
    }

    /// Formatting is kfmt's, run as the same binary a terminal would run, so
    /// the editor and `kfmt --write` can never disagree.
    fn formatting(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "null")
            return
        }

        var kfmt = self.tool("kfmt")
        if kfmt.empty() {
            self.respond_error(id, -32803, "kfmt was not found beside kals or on PATH")
            return
        }

        var src = self.scratch(".k")
        var out = self.scratch(".fmt")
        LinkFS::write(src, self.docs.docs[i].text)

        var argv: [string]
        argv.push_back(kfmt)
        argv.push_back("--stdout")
        argv.push_back(src)
        var rc = self.run_and_wait(&argv, out)

        var text: string = ""
        var read = LinkFS::read(out, &text)
        Path::remove_file(src)
        Path::remove_file(out)

        if (rc != 0) || (!read) {
            // kfmt refuses a file that does not parse, and says where: its
            // first line is the reason, with the scratch name taken out.
            var why: string = ""
            for var k: usize = 0; (k < text.size()) && (text[k] != 10) && (k < 300); ++k {
                why.push_back(text[k])
            }

            if why.starts_with(src) {
                why = why.subslice(src.size(), why.size() - src.size())
            }

            self.say(2, "kfmt did not format " + self.docs.docs[i].path + why)
            self.respond_error(id, -32803, "kfmt did not format this file" + why)
            return
        }

        var *old = &self.docs.docs[i].text
        if text == *old {
            self.respond(id, "[]")
            return
        }

        // The smallest whole-line edit that turns the buffer into kfmt's
        // output: an editor keeps cursors, folds and marks outside it, which
        // a replace-everything edit throws away.
        var a: usize = 0
        while (a < old->size()) && (a < text.size()) && ((*old)[a] == text[a]) {
            a += 1
        }

        while (a > 0) && ((*old)[a - 1] != 10) {
            a -= 1
        }

        var oe = old->size()
        var ne = text.size()
        while (oe > a) && (ne > a) && ((*old)[oe - 1] == text[ne - 1]) {
            oe -= 1
            ne -= 1
        }

        while (oe < old->size()) && ((*old)[oe - 1] != 10) && (oe > 0) {
            oe += 1
            ne += 1
        }

        if oe > old->size() {
            oe = old->size()
        }

        if ne > text.size() {
            ne = text.size()
        }

        if ne < a {
            ne = a
        }

        // Range formatting: kfmt formats a file, so the answer is its edit
        // when that edit lies inside the lines asked for, and nothing
        // otherwise (never a change the user did not select).
        var rr = d->get(params, "range")
        if d->is_object(rr) {
            var lo = d->get_int(d->get(rr, "start"), "line") as usize
            var hi = d->get_int(d->get(rr, "end"), "line") as usize
            var el = self.docs.docs[i].lines.line_of(a)
            var eh = self.docs.docs[i].lines.line_of(if oe > a => (oe - 1) else => a)
            if (el < lo) || (eh > hi) {
                self.respond(id, "[]")
                return
            }
        }

        var w = JsonWriter()
        w.begin_array()
        w.begin_object()
        w.key("range")
        w.begin_object()
        w.key("start")
        self.write_pos(&w, i, a)
        w.key("end")
        self.write_pos(&w, i, oe)
        w.end_object()
        w.field("newText", text.subslice(a, ne - a))
        w.end_object()
        w.end_array()
        self.respond(id, w.out)
    }

    /// Completion runs its own worker on a copy of the buffer with a marker
    /// identifier where the cursor is (Indexer.k: completion_marker).
    fn completion(self, d: *const JsonDoc, params: u32, const id: string) {
        // Scans the whole text: materialise the edited buffers (O(document),
        // once per request, never per keystroke).
        self.docs.sync_all()
        var i = self.docs.index_of(d->get_str(d->get(params, "textDocument"), "uri"))
        if i == usize::MAX {
            self.respond(id, "[]")
            return
        }

        if self.running(JOB_COMPLETE()) > 0 {
            if !self.comp_wait_id.empty() {
                self.respond(self.comp_wait_id, "{\"isIncomplete\":true,\"items\":[]}")
            }

            self.comp_wait    = d->dump(d->root)
            self.comp_wait_id = id
            return
        }

        var path = self.docs.docs[i].path
        var ei   = self.ensure_entry(path)
        if ei == usize::MAX {
            self.respond(id, "{\"isIncomplete\":true,\"items\":[]}")
            return
        }

        var pos  = d->get(params, "position")
        var *text = &self.docs.docs[i].text
        var at = self.docs.docs[i].lines.offset(
            *text,
            d->get_int(pos, "line") as usize,
            d->get_int(pos, "character") as usize,
            false,
        )

        // The identifier under the cursor, both halves: the marker replaces
        // all of it, and the editor filters the items by what was typed.
        var start = at
        while (start > 0) && is_ident_byte((*text)[start - 1]) {
            start -= 1
        }

        var end = at
        while (end < text->size()) && is_ident_byte((*text)[end]) {
            end += 1
        }

        var before = start
        while (before > 0) && (((*text)[before - 1] == 32) || ((*text)[before - 1] == 9)) {
            before -= 1
        }

        var member = false
        if before > 0 {
            var c = (*text)[before - 1]
            member = (c == 46) || (c == 58) || ((c == 62) && (before > 1) && ((*text)[before - 2] == 45))
        }

        // What an accepted item replaces: the identifier under the cursor.
        var ew = JsonWriter()
        ew.begin_object()
        ew.key("start")
        self.write_pos(&ew, i, start)
        ew.key("end")
        self.write_pos(&ew, i, at)
        ew.end_object()

        if self.complete_import(i, ei, at, ew.out, id) {
            return
        }

        var marked = text->subslice(0, start)
        marked += completion_marker()
        marked += text->subslice(end, text->size() - end)

        var j = Job()
        j.kind   = JOB_COMPLETE()
        j.entry  = ei
        j.out    = self.scratch(".json")
        j.log    = self.scratch(".log")
        j.rev    = self.rev
        j.id     = id
        j.path   = path
        j.member = member
        j.edit   = ew.out
        j.marked = self.scratch(".k")
        LinkFS::write(j.marked, marked)

        var argv = self.worker_argv(ei, j.out, path, j.marked)
        if !self.launch(&argv, j.log, &j.pi) {
            self.respond(id, "[]")
            return
        }

        self.jobs.push_back(j)
    }

    /// One completion item. \p edit is the range it replaces: stated on every
    /// item, because an editor left to guess the range guesses by its own
    /// idea of a word, which is not Kairo's inside a string or after `::`
    /// (Zed drops such items as "out of expected range").
    fn item(self,
            w:            *JsonWriter,
            const label:  string,
            kind:         i64,
            const detail: string,
            const sort:   string,
            const edit:   string) {
        w->begin_object()
        w->field("label", label)
        w->field_int("kind", kind)
        if !detail.empty() {
            w->field("detail", detail)
        }

        if !sort.empty() {
            w->field("sortText", sort)
        }

        if !edit.empty() {
            w->key("textEdit")
            w->begin_object()
            w->field_raw("range", edit)
            w->field("newText", label)
            w->end_object()
        }

        w->end_object()
    }

    /// `import a::b::|` and `import a::b::{x, |`: answered from the
    /// filesystem, with no compile. A path names directories and `.k` files
    /// under the search roots, and after a file, what that file declares.
    /// True when the cursor was in an import (and the request is answered).
    fn complete_import(self, i: usize, ei: usize, at: usize, const edit: string, const id: string) -> bool {
        var *text = &self.docs.docs[i].text
        var ls = self.docs.docs[i].lines.starts[self.docs.docs[i].lines.line_of(at)]

        // An import may span lines inside its braces: start from the nearest
        // line above that begins the statement.
        var stmt = ls
        var guard: usize = 0
        while guard < 64 {
            var p = stmt
            while (p < at) && (((*text)[p] == 32) || ((*text)[p] == 9)) {
                p += 1
            }

            var line = text->subslice(p, at - p)
            if line.starts_with("import ") || line.starts_with("pub import ") || line.starts_with("priv import ")
                || line.starts_with("prot import ") {
                stmt = p
                break
            }

            if stmt == 0 {
                return false
            }

            // Only keep walking up while inside an open `{`.
            var prev = self.docs.docs[i].lines.line_of(stmt - 1)
            stmt = self.docs.docs[i].lines.starts[prev]
            guard += 1
        }

        if guard >= 64 {
            return false
        }

        var head = text->subslice(stmt, at - stmt)
        var k = find_from(head, "import ", 0)
        if k == usize::MAX {
            return false
        }

        var spec = head.subslice(k + 7, head.size() - k - 7)
        // A closed brace list, or a statement that already ended, is not an
        // import being typed.
        if (find_from(spec, "}", 0) != usize::MAX) || (find_from(spec, ";", 0) != usize::MAX) {
            return false
        }

        if (stmt != ls) && (find_from(spec, "{", 0) == usize::MAX) {
            return false
        }

        // Split at `::` into path segments; inside braces the last segment is
        // an item being typed, not part of the path.
        var segs: [string]
        var cur = string()
        var in_items = false
        var q: usize = 0
        while q < spec.size() {
            var c = spec[q]
            if in_items {
                q += 1
                continue
            }

            if (c == 58) && ((q + 1) < spec.size()) && (spec[q + 1] == 58) {
                segs.push_back(cur)
                cur = string()
                q += 2
                continue
            }

            if c == 123 {
                in_items = true
            } else if is_ident_byte(c) {
                cur.push_back(c)
            }

            q += 1
        }

        // Where a path can start: the file's own directory, the entry's
        // directory and its -I roots, and the parent of every library root
        // the last run read (a directory holding a module.k is a module, so
        // its parent is where its name resolves from).
        var roots: [string]
        roots.push_back(Path::parent_of(self.docs.docs[i].path))
        if ei != usize::MAX {
            roots.push_back(self.entries[ei].dir)
            for var a: usize = 0; (a + 1) < self.entries[ei].args.size(); ++a {
                if self.entries[ei].args[a] == "-I" {
                    roots.push_back(Path::absolute_if_exists(self.entries[ei].args[a + 1], self.entries[ei].dir))
                }
            }

            for var f: usize = 0; f < self.entries[ei].files.size(); ++f {
                if Path::filename_of(self.entries[ei].files[f]) == "module.k" {
                    var lib = Path::parent_of(self.entries[ei].files[f])
                    roots.push_back(Path::parent_of(lib))
                }
            }
        }

        var seen: [string]
        var w = JsonWriter()
        w.begin_object()
        w.field_bool("isIncomplete", false)
        w.key("items")
        w.begin_array()

        var rel: string = ""
        for var g: usize = 0; g < segs.size(); ++g {
            rel = Path::join_str(rel, segs[g])
        }

        for var r: usize = 0; r < roots.size(); ++r {
            var dir = roots[r]
            if !rel.empty() {
                dir = Path::join_str(roots[r], rel)
            }

            // The path so far names a FILE: offer what it declares.
            var file = dir + ".k"
            if (!rel.empty()) && (!Path::exists_at(file)) {
                file = Path::join_str(dir, "module.k")
            }

            if (!rel.empty()) && Path::exists_at(file) {
                var src: string = ""
                if LinkFS::read(file, &src) {
                    var names = top_level_names(src)
                    for var n: usize = 0; n < names.size(); ++n {
                        var dup = false
                        for var z: usize = 0; z < seen.size(); ++z {
                            if seen[z] == names[n] {
                                dup = true
                            }
                        }

                        if !dup {
                            seen.push_back(names[n])
                            self.item(&w, names[n], 3, Path::filename_of(file), "1" + names[n], edit)
                        }
                    }
                }
            }

            if in_items {
                continue
            }

            // And a DIRECTORY: its files and sub-directories are the next
            // segment.
            var names = LinkFS::list_dir(dir)
            for var n: usize = 0; n < names.size(); ++n {
                var name = names[n]
                var kind: i64 = 19
                if name.ends_with(".k") {
                    name = name.subslice(0, name.size() - 2)
                    kind = 9
                    if name == "module" {
                        continue
                    }
                } else if (!LinkFS::is_dir(Path::join_str(dir, name))) || name.starts_with(".") {
                    continue
                }

                // At the top level only library roots are offered from a
                // library's parent directory, not everything beside them.
                if rel.empty() && (r >= 2) {
                    // A library is a directory with a module.k: `std` sits
                    // beside `builtin` and is one whether or not this file
                    // has imported it yet.
                    var is_lib = (kind == 19) && LinkFS::is_file(Path::join_str(Path::join_str(dir, name), "module.k"))

                    var from_i = (ei != usize::MAX) && (r < (2 + (self.entries[ei].args.size() / 2)))
                    if (!is_lib) && (!from_i) {
                        continue
                    }
                }

                var dup = false
                for var z: usize = 0; z < seen.size(); ++z {
                    if seen[z] == name {
                        dup = true
                    }
                }

                if !dup {
                    seen.push_back(name)
                    self.item(&w, name, kind, "", "0" + name, edit)
                }
            }
        }

        w.end_array()
        w.end_object()
        self.respond(id, w.out)
        return true
    }

    fn finish_complete(self, j: *Job, rc: i32) {
        if j->cancelled {
            return
        }

        var text: string = ""
        var doc = JsonDoc()
        var w = JsonWriter()
        w.begin_object()
        w.field_bool("isIncomplete", false)
        w.key("items")
        w.begin_array()

        var found = false
        if LinkFS::read(j->out, &text) && doc.parse(text) {
            var f = doc.first(doc.get(doc.root, "files"))
            while f != JSON_NONE() {
                if doc.get_str(f, "path") == j->path {
                    var it = doc.first(doc.get(f, "items"))
                    self.item_labels.clear()
                    self.item_docs.clear()
                    while it != JSON_NONE() {
                        var idoc = doc.get_str(it, "doc")
                        if !idoc.empty() {
                            self.item_labels.push_back(doc.get_str(it, "label"))
                            self.item_docs.push_back(idoc)
                        }

                        self.item(
                            &w,
                            doc.get_str(it, "label"),
                            doc.get_int(it, "kind"),
                            doc.get_str(it, "detail"),
                            doc.get_str(it, "sortText"),
                            j->edit,
                        )

                        found = true
                        it = doc.next(it)
                    }
                }

                f = doc.next(f)
            }
        }

        if (!found) && (!j->member) && (j->entry < self.entries.size()) {
            // The marked buffer did not get as far as Sema (it does not
            // parse yet). The last good outline of the file is better than
            // nothing for a bare name.
            var fn_ = self.file_node(j->entry, j->path)
            if fn_ != JSON_NONE() {
                var *s = &self.entries[j->entry].idx
                var c = s->first(s->get(fn_, "symbols"))
                while c != JSON_NONE() {
                    self.item(&w, s->get_str(c, "name"), 6, "", "", j->edit)
                    c = s->next(c)
                }
            }
        }

        if !j->member {
            var kw = keywords()
            for var k: usize = 0; k < kw.size(); ++k {
                self.item(&w, kw[k], 14, "", "9" + kw[k], j->edit)
            }
        }

        w.end_array()
        w.end_object()
        self.respond(j->id, w.out)
    }

    // --- the loop --------------------------------------------------------

    fn run(self) -> i32 {
        while !self.quit {
            var got = self.t.wait(self.wait_ms())
            if got {
                self.handle(self.t.take())
                continue // drain the queue before starting anything
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
                    && ((now - self.jobs[q].started_ms) > 1000) {
                    self.entries[je].slow = true
                    self.retry_parked(false)
                }
            }

            self.report_progress()

            // The syntax-only pass of each edited buffer, on its own (shorter)
            // debounce, one at a time per buffer.
            if (now - self.last_change_ms) >= self.syntax_ms {
                // At most two at once: each is a compiler process (about
                // 190 MB in a debug build), and a change that touches many
                // buffers (a rename) must not start one per buffer.
                for var k: usize = 0; k < self.docs.docs.size(); ++k {
                    if (!self.docs.docs[k].syn_running) && (self.docs.docs[k].changed_at > self.docs.docs[k].syn_started)
                        && (self.running(JOB_SYNTAX()) < 2) {
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

        if !self.tmp.empty() {
            Path::remove_tree(self.tmp)
        }

        return self.exit_code
    }
}

/// Offset of \p needle in \p hay at or after \p from, or usize::MAX.
pub fn find_from(const hay: string, const needle: string, from: usize) -> usize {
    if needle.empty() || (needle.size() > hay.size()) {
        return usize::MAX
    }

    var last = hay.size() - needle.size()
    for var i: usize = from; i <= last; ++i {
        var m: usize = 0
        while (m < needle.size()) && (hay[i + m] == needle[m]) {
            m += 1
        }

        if m == needle.size() {
            return i
        }
    }

    return usize::MAX
}

/// ASCII lower-casing: symbol search ignores case.
pub fn lower(const s: string) -> string {
    var out = string()
    for var i: usize = 0; i < s.size(); ++i {
        var c = s[i]
        if (c >= 65) && (c <= 90) {
            c = c + 32
        }

        out.push_back(c)
    }

    return out
}

/// Names a file declares at its top level, read from its text: a line that
/// starts (after an optional visibility keyword) with a declaring keyword and
/// a name. Private-looking names (a leading or trailing underscore) and
/// `priv` declarations are left out: an import cannot name them.
pub fn top_level_names(const src: string) -> [string] {
    var out: [string]
    var kws = keyword_list("fn class struct enum union interface type const var static eval macro module")
    var i: usize = 0
    var n = src.size()
    while i < n {
        // one line, which must start in column 0 to be top level
        var le = i
        while (le < n) && (src[le] != 10) {
            le += 1
        }

        var p = i
        var line = src.subslice(i, le - i)
        var hidden = line.starts_with("priv ")
        if line.starts_with("pub ") || line.starts_with("prot ") || line.starts_with("priv ") {
            while (p < le) && (src[p] != 32) {
                p += 1
            }

            p += 1
        }

        // skip modifiers before the declaring keyword (`inline fn`, `unsafe fn`)
        for var m: usize = 0; m < 3; ++m {
            var rest = src.subslice(p, le - p)
            if rest.starts_with("inline ") || rest.starts_with("unsafe ") || rest.starts_with("async ")
                || rest.starts_with("final ") || rest.starts_with("virtual ") {
                while (p < le) && (src[p] != 32) {
                    p += 1
                }

                p += 1
            }
        }

        var we = p
        while (we < le) && is_ident_byte(src[we]) {
            we += 1
        }

        var word = src.subslice(p, we - p)
        var declares = false
        for var k: usize = 0; k < kws.size(); ++k {
            if kws[k] == word {
                declares = true
            }
        }

        if declares && (!hidden) && (we < le) && (src[we] == 32) {
            var ns = we + 1
            // `fn <T> name(` : skip a generic list before the name
            if (ns < le) && (src[ns] == 60) {
                while (ns < le) && (src[ns] != 62) {
                    ns += 1
                }

                ns += 1
                while (ns < le) && (src[ns] == 32) {
                    ns += 1
                }
            }

            var ne = ns
            while (ne < le) && is_ident_byte(src[ne]) {
                ne += 1
            }

            var name = src.subslice(ns, ne - ns)
            if (ne > ns) && (name != "op") && (!name.starts_with("_")) && (!name.ends_with("_")) {
                var dup = false
                for var z: usize = 0; z < out.size(); ++z {
                    if out[z] == name {
                        dup = true
                    }
                }

                if !dup {
                    out.push_back(name)
                }
            }
        }

        i = le + 1
    }

    return out
}

pub fn keyword_list(const all: string) -> [string] {
    var k: [string]
    var cur = string()
    for var i: usize = 0; i < all.size(); ++i {
        if all[i] == 32 {
            if !cur.empty() {
                k.push_back(cur)
            }

            cur = string()
        } else {
            cur.push_back(all[i])
        }
    }

    if !cur.empty() {
        k.push_back(cur)
    }

    return k
}

pub fn is_ident_byte(c: u8) -> bool {
    return ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || ((c >= 48) && (c <= 57)) || (c == 95) || (c >= 128)
}

/// Offered wherever a bare name can start. The spellings are the language
/// reference's; the lexer has no table to read them from.
pub fn keywords() -> [string] {
    var k: [string]
    var all = "fn var const static eval if else unless while for loop match case default return break continue " +
        "class struct enum union interface extend impl derives module import ffi pub priv prot " +
        "unsafe inline virtual override final async await spawn yield try catch finally panic " +
        "true false null self Self as in is where requires type macro test delete sizeof alignof typeof " +
        "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char byte void string"
    var cur = string()
    for var i: usize = 0; i < all.size(); ++i {
        if all[i] == 32 {
            if !cur.empty() {
                k.push_back(cur)
            }

            cur = string()
        } else {
            cur.push_back(all[i])
        }
    }

    if !cur.empty() {
        k.push_back(cur)
    }

    return k
}

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
