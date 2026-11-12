/// --- The Kairo Project ------------------ Analyzer/Server/Scheduling.k --- ///
///
///   Entries, jobs and parked requests: which entry point holds a file, when a request waits.
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
ffi "c" import "kals_io.h"
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
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::Workers::*
import Server::LiveIndex::*

/// What a worker process in flight is for. A job's kind never changes; the
/// fields of Job each kind uses are marked with it.
pub enum JobKind derives u8 {
    Index,     ///< a run of an entry (`kals --worker`): its snapshot
    Complete,  ///< a completion request's run on a marked copy of the buffer

    /// A syntax-only pass over one buffer (`kals --worker ... --syntax-only`):
    /// its parse errors and lexical tokens, long before the Sema run lands.
    Syntax,

    /// The clangd bridge's header job (LanguageServer.md section 15): one `.k`
    /// file a C or C++ source includes, checked as a module, its interop header
    /// written with `#line` directives into `<project>/.kairo/clangd/`.
    Header,
}

/// The name of \p k in the trace.
pub fn job_kind_name(k: JobKind) -> string {
    if k == JobKind::Index {
        return "index"
    }

    if k == JobKind::Complete {
        return "complete"
    }

    if k == JobKind::Syntax {
        return "syntax"
    }

    return "header"
}

/// Whether an entry can answer a request now (Server::answerability;
/// LanguageServer.md section 9).
pub enum Answer derives u8 {
    Fresh,          ///< its last run is of the current text: answer
    StaleSlow,      ///< a run is due or running, and runs are slow: answer from the last index
    StaleWaitable,  ///< a run is due or running, and fast: park the request
    FirstPending,   ///< no index yet, and its first is due or running: wait for it
    NoEntry,        ///< no entry holds the file yet (one is being tried): park
}

/// What Server::launch_job did with a worker. A start function makes its
/// owner's "started" transition only on Started; Refused leaves the work
/// due, to be tried again after the launch backoff.
pub enum LaunchResult derives u8 {
    Started,
    Refused,
}

/// Milliseconds on a monotonic clock: debounce deadlines and run lengths.
pub fn now_ms() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    var d = cxx::std::chrono::duration_cast<cxx::std::chrono::milliseconds>(t.time_since_epoch())
    return d.count() as i64
}

/// Microseconds on the same clock: the install timers (trace `install`).
pub fn now_us() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    var d = cxx::std::chrono::duration_cast<cxx::std::chrono::microseconds>(t.time_since_epoch())
    return d.count() as i64
}

/// The persistent syntax worker's state (SyntaxChild::state).
pub enum SynWorker derives u8 {
    NotRunning,
    Idle,
    Busy,
    Failed,
}

/// The persistent syntax worker (`kals --worker --syntax-server`, section
/// 11 item 2a): one process, fed buffers over its stdin, answering on its
/// stdout. One request in flight at a time: a second write while it is
/// still answering the first could fill both pipes and deadlock the two.
pub class SyntaxChild {
    /// NotRunning -> Idle (spawned) or Failed; Idle -> Busy (a request
    /// sent); Busy -> Idle (answered) or, lost (EOF, a timeout), stopped
    /// and spawned again or Failed past SYNTAX_SERVER_MAX_RESTARTS.
    /// Failed is for the session: the per-process path takes every pass.
    pub var state:    SynWorker = SynWorker::NotRunning
    pub var pid:      i64  = -1     ///< Idle and Busy: the process
    pub var t:        Transport     ///< over its pipes (fd_in, fd_out)
    pub var passes:   u64  = 0      ///< answers since it started: it is recycled (Tuning.k)
    pub var restarts: u64  = 0      ///< deaths and timeouts: past the cap, the per-process path only

    /// Busy only: the request in flight.
    pub var id:      i64    = 0     ///< its id
    pub var path:    string = ""    ///< its buffer
    pub var rev:     u64    = 0     ///< the server revision it saw
    pub var sent_ms: i64    = 0

    fn SyntaxChild(self) = default

    fn running(const self) -> bool {
        return (self.state == SynWorker::Idle) || (self.state == SynWorker::Busy)
    }

    fn busy(const self) -> bool {
        return self.state == SynWorker::Busy
    }

    /// No pipes on this platform, or it keeps dying.
    fn failed(const self) -> bool {
        return self.state == SynWorker::Failed
    }
}

/// A request sent to a live index worker and not answered yet.
pub class LiveSent {
    pub var id:  i64    = 0
    pub var rev: u64    = 0     ///< the server revision it saw
    pub var out: string = ""    ///< where its snapshot is written
    pub var ms:  i64    = 0     ///< now_ms() when it was sent

    /// The buffers it was sent, as Job::text_paths / texts.
    pub var text_paths: [string]
    pub var texts:      [string]

    /// As Job's: the work-done progress token shown for it (empty: none),
    /// the file the worker counts checked files into, the last count.
    pub var progress:  string = ""
    pub var prog_file: string = ""
    pub var prog_n:    i64    = -1

    /// Its first tier is installed and the files that import the edited
    /// ones are being re-checked: more answers come under this id.
    pub var draining: bool = false

    fn LiveSent(self) = default
}

/// A live index worker (`kals --worker --index-server`, LiveIndex.k): one
/// process holding one entry's checked graph.
pub class LiveChild {
    pub var entry:    string = ""    ///< the entry file it holds
    pub var pid:      i64    = -1    ///< -1: not running
    pub var t:        Transport      ///< over its pipes
    pub var steps:    u64    = 0     ///< answers since it started
    pub var restarts: u64    = 0     ///< deaths and timeouts
    pub var failed:   bool   = false ///< no pipes here, or it keeps dying: a process per run
    pub var base_rss: i64    = -1    ///< resident MB after its first check
    pub var rss:      i64    = -1    ///< resident MB after its last answer
    pub var last_ms:  i64    = 0     ///< now_ms() of its last answer

    /// The next run of the entry is a process: the worker died on, or
    /// could not take, the text as it stands.
    pub var skip_once: bool = false

    pub var sent: [LiveSent]         ///< in flight, oldest first

    fn LiveChild(self) = default
}

/// A worker process in flight.
pub class Job {
    pub var kind:   JobKind = JobKind::Index

    /// Index, Complete: the Entry::id it runs for. An id, not an
    /// index into Server::entries: load_project rebuilds that list while
    /// jobs are in flight, and a result whose entry is gone is dropped
    /// (Server::entry_by_id) instead of landing in whichever entry took
    /// its old place.
    pub var entry_id: u64  = 0
    pub var pi:     llvm::sys::ProcessInfo
    pub var out:    string = ""     ///< the JSON the worker writes
    pub var log:    string = ""     ///< its stdout and stderr
    pub var rev:    u64    = 0      ///< server revision the run saw
    pub var id:     string = ""     ///< Complete: the request id, as JSON
    pub var path:   string = ""     ///< Complete: the buffer completed in
    pub var member: bool   = false  ///< Complete: after `.`, `->` or `::`
    pub var marked: string = ""     ///< Complete: the marked copy of the buffer
    pub var edit:   string = ""     ///< Complete: the range an accepted item replaces, as JSON
    pub var cancelled: bool = false ///< Complete: already answered "cancelled"; drop the result
    pub var started_ms: i64 = 0
    pub var rooted: bool = true    ///< Index: run with `--root` (worker_argv)

    /// Index: killed because its entry changed under it (touch). Its
    /// result is dropped, and its exit is not a crash to report.
    pub var stale: bool = false

    /// Index: the work-done progress token shown for this run (empty:
    /// none), the file the worker counts checked files into, and the last
    /// count reported.
    pub var progress:  string = ""
    pub var prog_file: string = ""
    pub var prog_n:    i64    = -1

    /// Index: each overlaid buffer's path and the text it was handed
    /// as, captured when the run starts. The buffer has usually moved on by
    /// the time the run lands, and an index is only ever mapped onto the
    /// text it read (Document::idx_text).
    pub var text_paths: [string]
    pub var texts:      [string]

    /// Index: the answer of a live index worker, installed through
    /// finish_index like a run's output: what the worker did (`full`: the
    /// whole graph; `refresh`: the files below), how many files it
    /// re-checked, and how many are still to come.
    pub var live:        bool   = false
    pub var l_mode:      string = ""
    pub var l_why:       string = ""
    pub var l_rechecked: usize  = 0
    pub var l_pending:   usize  = 0

    fn Job(self) = default
}

/// One entry point: its command, its last snapshot, and how stale that is.
pub class Entry {
    /// Stable for the life of the entry, never reused (Server::entry_seq):
    /// what a job names its entry by. 0 is no entry.
    pub var id:    u64    = 0

    /// The entry file. Empty: retired (an ad-hoc entry a project entry now
    /// answers for, Server::retire_); it keeps its place in the list.
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
    pub var rooted:   bool = true   ///< the last worker_argv passed `--root`

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
    /// Files changed on disk that the entry's live index worker has not
    /// been told of (touch adds, a live request takes them).
    pub var live_changed: [string]

    /// Files the live worker has still to re-check after an edit (they
    /// import an edited file). Their rows and diagnostics are the ones from
    /// before the edit until then: positions in their own text are exact,
    /// what they say about the edited file may not be.
    pub var live_pending: usize = 0

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
    pub var since: i64    = 0   ///< now_ms() when it was parked

    fn Parked(self) = default
}

extend Server {
    /// Adds \p e to the entry list under a new id; its index.
    fn add_entry_(self, @inout e: Entry) -> usize {
        self.entry_seq += 1
        e.id = self.entry_seq
        self.entries.push_back(e)
        return self.entries.size() - 1
    }

    /// The index of the live (not retired) entry with id \p id, or
    /// usize::MAX: the project was reloaded, or the entry retired, under
    /// whoever holds the id.
    fn entry_by_id(const self, id: u64) -> usize {
        if id == 0 {
            return usize::MAX
        }

        for var i: usize = 0; i < self.entries.size(); ++i {
            if (self.entries[i].id == id) && (!self.entries[i].entry.empty()) {
                return i
            }
        }

        return usize::MAX
    }

    /// Kills every index run of entry \p id (0: of every entry). Its result
    /// is dropped as a stale run's is, and reap still ends its progress.
    fn disown_runs_(self, id: u64) {
        for var q: usize = 0; q < self.jobs.size(); ++q {
            if (self.jobs[q].kind != JobKind::Index) || self.jobs[q].stale {
                continue
            }

            if (id == 0) || (self.jobs[q].entry_id == id) {
                self.jobs[q].stale = true
                self.trace(f"index disowned entry_id={self.jobs[q].entry_id} rev={self.jobs[q].rev}")
                unsafe kals_kill(self.jobs[q].pi.Pid as i64)
            }
        }
    }

    /// Retires ad-hoc entry \p k: a project entry's graph holds its file
    /// now and answers for it. Its diagnostics are cleared and its run in
    /// flight, if any, is killed and disowned (entry_by_id no longer finds
    /// it), so nothing it computed lands or is published.
    fn retire_(self, k: usize) {
        self.clear_published_(k)
        self.disown_runs_(self.entries[k].id)
        self.trace("entry retired " + self.entries[k].entry)
        self.entries[k].files.clear()
        self.entries[k].entry    = ""
        self.entries[k].has_snap = false
        self.entries[k].has_idx  = false
        self.entries[k].dirty    = false
        self.entries[k].running  = false
    }

    fn clear_published_(self, ei: usize) {
        for var i: usize = 0; i < self.entries[ei].published.size(); ++i {
            var w = JsonWriter()
            w.begin_object()
            w.field("uri", self.entries[ei].published[i])
            w.field_raw("diagnostics", "[]")
            w.end_object()
            self.notify(M_PUBLISH_DIAGNOSTICS, w.out)
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
        return self.add_entry_(&e)
    }

    /// The entry that already answers for buffer \p di as it is: its last
    /// run is current, indexed the file, and read from the disk the very
    /// text the buffer holds. usize::MAX when a run is needed (an edited
    /// buffer, a file the last run did not index, an entry not yet run).
    fn unchanged_on_disk_(self, di: usize) -> usize {
        var path = self.docs.docs[di].path
        var ei = self.entry_of(path)
        if (ei == usize::MAX) || (!self.entries[ei].fresh()) || (!self.entries[ei].has_idx)
            || (self.entries[ei].idx_rev == 0) || (self.entries[ei].idx_rev < self.entries[ei].done_rev) {
            return usize::MAX
        }

        if self.file_node(ei, path) == JSON_NONE() {
            return usize::MAX
        }

        self.docs.docs[di].sync() // `text` is materialised lazily
        var disk: string = ""
        if (!LinkFS::read(path, &disk)) || (disk != self.docs.docs[di].text) {
            return usize::MAX
        }

        return ei
    }

    /// Marks every entry that reads \p path as needing a run.
    fn touch(self, const path: string) {
        self.rev += 1
        self.last_change_ms = now_ms()
        var di = self.docs.index_of_path(path)
        if di != usize::MAX {
            self.docs.docs[di].changed_at = self.rev
            self.docs.docs[di].changed_ms = self.last_change_ms
        }

        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].holds(path) {
                self.entries[i].dirty      = true
                self.entries[i].change_rev = self.rev
                // A buffer's text the live worker compares itself; only
                // a change on DISK has to be named to it.
                if self.live_on && (di == usize::MAX) {
                    var have = false
                    for var q: usize = 0; q < self.entries[i].live_changed.size(); ++q {
                        if self.entries[i].live_changed[q] == path {
                            have = true
                        }
                    }

                    if !have {
                        self.entries[i].live_changed.push_back(path)
                    }
                }
            }
        }

        // A slow run of the text before this change can only produce answers
        // the editor refuses (ContentModified), and the entry cannot start
        // again until it ends: without this an edit made during a run waits
        // out the rest of it and then a whole second one. Only a run known
        // to be slow, and never an entry's first: a fast one is done before
        // the kill would matter, and a first index has nothing older to show.
        for var q: usize = 0; q < self.jobs.size(); ++q {
            if (self.jobs[q].kind != JobKind::Index) || self.jobs[q].stale {
                continue
            }

            var je = self.entry_by_id(self.jobs[q].entry_id)
            if (je != usize::MAX) && self.entries[je].ran && self.entries[je].slow
                && self.entries[je].holds(path) {
                self.jobs[q].stale = true
                self.trace(f"index kill entry={self.entries[je].entry} rev={self.jobs[q].rev}")
                unsafe kals_kill(self.jobs[q].pi.Pid as i64)
            }
        }

        if is_cxx_source(path) {
            self.br_rescan = true
            self.br_changed.push_back(path)
            var told = false
            for var q: usize = 0; q < self.br_told.size(); ++q {
                if self.br_told[q] == path {
                    told = true
                }
            }

            if !told {
                self.br_told.push_back(path)
            }

            // Most recent last, bounded: its .k files' headers go first.
            var others: [string]
            for var q: usize = 0; q < self.br_recent.size(); ++q {
                if self.br_recent[q] != path {
                    others.push_back(self.br_recent[q])
                }
            }

            var recent: [string]
            var from: usize = 0
            if (others.size() + 1) > BRIDGE_RECENT_SOURCES {
                from = others.size() + 1 - BRIDGE_RECENT_SOURCES
            }

            for var q = from; q < others.size(); ++q {
                recent.push_back(others[q])
            }

            recent.push_back(path)
            self.br_recent = recent
        }

        for var b: usize = 0; b < self.br_files.size(); ++b {
            if (self.br_files[b] == path) || (find_from(self.br_deps[b], path + "\n", 0) != usize::MAX) {
                self.br_dirty[b] = true
            }
        }
    }

    // --- the clangd bridge (section 15) ------------------------------------

    /// How long the loop may wait for a message: the transport's 40 ms, or
    /// less when a debounce deadline falls sooner, so a pass starts on time
    /// rather than on the next 40 ms boundary.
    fn wait_ms(const self) -> i32 {
        // Only what the loop would START when the wait ends: an entry that
        // can_start refuses (another run holds the slot) is no deadline, or
        // the loop would spin at 1 ms turns for the whole of that run. A
        // deadline already passed is started on this turn, so it is not one
        // either.
        var best: i64 = IDLE_WAIT_MS
        var since = now_ms() - self.last_change_ms
        var syn_due = false
        for var k: usize = 0; k < self.docs.docs.size(); ++k {
            if self.docs.docs[k].syn_due() {
                syn_due = true
            }
        }

        // Only the fallback path has a deadline: the persistent worker is
        // fed on the turn of the change itself (syntax_kick).
        var left = self.syntax_ms - since
        if syn_due && self.syn.failed() && (left > 0) && (left < best) {
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

        left = self.debounce_of(true) - since
        if run_due && (left > 0) && (left < best) {
            best = left
        }

        return best as i32
    }

    /// The quiet time before a run of an entry: longer when its runs are
    /// slow (Tuning.k), never shorter than what the editor asked for.
    fn debounce_of(const self, slow: bool) -> i64 {
        if slow && (self.debounce_ms < SLOW_ENTRY_DEBOUNCE_MS) {
            return SLOW_ENTRY_DEBOUNCE_MS
        }

        return self.debounce_ms
    }

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
            var stale  = force && (waited >= PARK_LIMIT_MS)
            // A first index that has not come after two minutes is not coming.
            if !self.feature(old[i].msg, stale, waited >= FIRST_INDEX_LIMIT_MS) {
                self.parked.push_back(old[i])
            }
        }
    }

    // --- requests --------------------------------------------------------
}
