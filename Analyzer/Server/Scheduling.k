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

/// The clangd bridge's header job (LanguageServer.md section 15): one `.k`
/// file a C or C++ source includes, checked as a module, its interop header
/// written with `#line` directives into `<project>/.kairo/clangd/`.
pub fn JOB_HEADER() -> u32 {
    return 3
}

/// Milliseconds on a monotonic clock: debounce deadlines and run lengths.
pub fn now_ms() -> i64 {
    var t = cxx::std::chrono::steady_clock::now()
    var d = cxx::std::chrono::duration_cast<cxx::std::chrono::milliseconds>(t.time_since_epoch())
    return d.count() as i64
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

extend Server {
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

        if is_cxx_source(path) {
            self.br_rescan = true
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
                var p = old[i]
                p.turns += 1
                self.parked.push_back(p)
            }
        }
    }

    // --- requests --------------------------------------------------------
}
