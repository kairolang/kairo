/// --- The Kairo Project ------------------ Analyzer/Server/LiveIndex.k --- ///
///
///   The live index worker, server side (LanguageServer.md section 10;
///   Compiler/Spec/IncrementalSema.md phase 5). With
///   initializationOptions.liveCheck an entry's graph is kept checked in a
///   `kals --worker --index-server` process (Index/LiveWorker.k), and a
///   change is a request to it: the edited file and the files that import
///   it are re-checked, and the snapshot it writes is installed as a run's
///   is (finish_index).
///
///   A process per run (Workers.k start_index) stays the fallback and the
///   crash boundary: for an entry past LIVE_MAX_CHILDREN or one no project
///   lists, for a revision whose buffer does not parse (the live worker
///   keeps the last text that did), for the revision a worker died or timed
///   out on, and for the rest of a session in which it keeps dying.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


ffi "c" import "kals_io.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/Program.h"
ffi "c++" import "optional"
ffi "c++" import "string"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "chrono"

import DocumentStore::DocumentStore
import Protocol::*
import Tuning::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import std::io
import Server::Diagnostics::*
import Server::Output::*
import Server::Scheduling::*
import Server::Server::*
import Server::Workers::*
import Server::SyntaxWorker::*
import API::FS::LinkFS
import Support::FileIO::Path::Path

extend Server {
    /// The live child of entry \p ei, or usize::MAX.
    fn live_of(const self, ei: usize) -> usize {
        for var k: usize = 0; k < self.lives.size(); ++k {
            if self.lives[k].entry == self.entries[ei].entry {
                return k
            }
        }

        return usize::MAX
    }

    /// Requests in flight, over every child: scratch files they name must
    /// not be removed, and a live check counts as a run for can_start.
    fn live_inflight(const self) -> usize {
        var n: usize = 0
        for var k: usize = 0; k < self.lives.size(); ++k {
            n += self.lives[k].sent.size()
        }

        return n
    }

    /// Children busy with a request, other than entry \p ei's own.
    fn live_busy_others(const self, ei: usize) -> usize {
        var n: usize = 0
        for var k: usize = 0; k < self.lives.size(); ++k {
            if (!self.lives[k].sent.empty()) && (self.lives[k].entry != self.entries[ei].entry) {
                n += 1
            }
        }

        return n
    }

    /// Is entry \p ei analysed by a live worker? A project's entries only,
    /// the first LIVE_MAX_CHILDREN of them to ask: a file checked on its
    /// own is small, and a process for it costs nothing to keep correct.
    fn live_takes(self, ei: usize) -> bool {
        if (!self.live_on) || self.entries[ei].adhoc || self.entries[ei].entry.empty() {
            return false
        }

        var k = self.live_of(ei)
        if k != usize::MAX {
            return !self.lives[k].failed
        }

        if self.lives.size() >= LIVE_MAX_CHILDREN {
            return false
        }

        var c = LiveChild()
        c.entry = self.entries[ei].entry
        self.lives.push_back(c)
        return true
    }

    /// Requests of child \p k whose first answer has not come.
    fn live_waiting_(const self, k: usize) -> usize {
        var n: usize = 0
        for var q: usize = 0; q < self.lives[k].sent.size(); ++q {
            if !self.lives[k].sent[q].draining {
                n += 1
            }
        }

        return n
    }

    fn live_spawn_(self, k: usize, ei: usize) -> bool {
        if self.lives[k].failed {
            return false
        }

        if self.lives[k].pid >= 0 {
            return true
        }

        // '\n'-separated words: the shim's argv (kals_child_spawn).
        var words = self.exe + "\n--worker\n--index-server\n--cwd\n" + self.entries[ei].dir
        words += "\n--root\n" + self.project.dir + "\n--"
        for var i: usize = 0; i < self.entries[ei].args.size(); ++i {
            words += "\n" + self.entries[ei].args[i]
        }

        words += "\n" + self.entries[ei].entry
        var to_child: i32 = -1
        var from_child: i32 = -1
        var pid: i64 = unsafe kals_child_spawn(unsafe &words.raw()[0], words.size() as u64, unsafe &to_child, unsafe &from_child)
        if pid < 0 {
            self.lives[k].failed = true
            self.say(MSG_LOG, "live index worker unavailable here: " + self.entries[ei].entry + " is analysed by a process per run")
            return false
        }

        self.lives[k].pid      = pid
        self.lives[k].steps    = 0
        self.lives[k].base_rss = -1
        self.lives[k].sent.clear()
        self.lives[k].t        = Transport()
        self.lives[k].t.fd_in  = from_child
        self.lives[k].t.fd_out = to_child
        self.trace(f"live worker started pid={pid} entry={self.entries[ei].entry}")
        return true
    }

    fn live_stop_(self, k: usize) {
        if self.lives[k].pid < 0 {
            return
        }

        unsafe kals_child_stop(self.lives[k].pid, self.lives[k].t.fd_out, self.lives[k].t.fd_in)
        self.lives[k].pid = -1
        for var q: usize = 0; q < self.lives[k].sent.size(); ++q {
            self.garbage.push_back(self.lives[k].sent[q].out)
            self.live_progress_end_(&self.lives[k].sent[q])
        }

        self.lives[k].sent.clear()
    }

    /// A begin is always followed by an end, whatever became of the request.
    fn live_progress_end_(self, s: *LiveSent) {
        if !s->progress.empty() {
            self.progress(s->progress, "end", "", -1)
            s->progress = ""
        }

        if !s->prog_file.empty() {
            self.garbage.push_back(s->prog_file)
            s->prog_file = ""
        }
    }

    fn live_stop_all(self) {
        for var k: usize = 0; k < self.lives.size(); ++k {
            self.live_stop_(k)
        }

        self.lives.clear()
    }

    /// Sends entry \p ei's state to its live worker. False when this run
    /// is a process's instead (the caller starts one); true when a request
    /// went out, or one will on a later turn (a verdict is awaited, or
    /// another run holds the slot).
    fn live_send(self, ei: usize) -> bool {
        var k = self.live_of(ei)
        if k == usize::MAX {
            return false
        }

        // A process is running for this entry (a fallback run): its result
        // first, as a second process would wait.
        if self.entries[ei].running && (self.live_waiting_(k) == 0) {
            return true
        }

        if self.lives[k].skip_once {
            self.lives[k].skip_once = false
            return false
        }

        // One whole compile at a time unless every graph is small: the
        // rule of can_start, with a busy live worker counted as a run.
        if (self.live_waiting_(k) == 0) && ((!self.can_start(ei)) || (self.live_busy_others(ei) > 0 && (!self.entries[ei].ran))) {
            return true
        }

        // A changed buffer that does not parse cannot be re-checked in
        // place. The syntax pass says whether it does, a few milliseconds
        // after the change; it is waited for, briefly.
        var now = now_ms()
        for var b: usize = 0; b < self.docs.docs.size(); ++b {
            if self.entries[ei].ran && (!self.entries[ei].holds(self.docs.docs[b].path)) {
                continue
            }

            if !self.docs.docs[b].path.ends_with(".k") {
                continue
            }

            var known = self.docs.docs[b].syn_landed && (self.docs.docs[b].syn_at >= self.docs.docs[b].changed_at)
            if (!known) && (self.docs.docs[b].changed_at > 0) && ((now - self.docs.docs[b].changed_ms) < LIVE_SYNTAX_WAIT_MS) {
                return true
            }

            if known && (!self.docs.docs[b].syn_parsed) {
                self.trace(f"live skip entry={self.entries[ei].entry}: " + self.docs.docs[b].path + " does not parse")
                return self.live_waiting_(k) > 0
            }
        }

        if !self.live_spawn_(k, ei) {
            return false
        }

        self.docs.sync_all()
        var s = LiveSent()
        self.live_seq += 1
        s.id  = self.live_seq
        s.rev = self.rev
        s.out = self.scratch(".json")
        s.ms  = now

        var w = JsonWriter()
        w.begin_object()
        w.field_int("id", s.id)
        w.field("out", s.out)
        w.key("open")
        w.begin_array()
        for var b: usize = 0; b < self.docs.docs.size(); ++b {
            var path = self.docs.docs[b].path
            // Before the first run the entry's files are unknown, so every
            // buffer is offered; one the graph never loads is ignored.
            if self.entries[ei].ran && (!self.entries[ei].holds(path)) {
                continue
            }

            if (self.docs.docs[b].tmp_rev != self.docs.docs[b].revision) || self.docs.docs[b].tmp_path.empty() {
                if !self.docs.docs[b].tmp_path.empty() {
                    self.garbage.push_back(self.docs.docs[b].tmp_path)
                }

                self.docs.docs[b].tmp_path = self.scratch(".k")
                self.docs.docs[b].tmp_rev  = self.docs.docs[b].revision
                LinkFS::write(self.docs.docs[b].tmp_path, self.docs.docs[b].text)
            }

            w.begin_object()
            w.field("path", path)
            w.field("file", self.docs.docs[b].tmp_path)
            w.end_object()
            s.text_paths.push_back(path)
            s.texts.push_back(self.docs.docs[b].text)
        }

        w.end_array()
        w.key("changed")
        w.begin_array()
        for var q: usize = 0; q < self.entries[ei].live_changed.size(); ++q {
            w.str(self.entries[ei].live_changed[q])
        }

        w.end_array()
        // A first check, or one already known to be slow, shows progress,
        // as a run does (start_index).
        var want = (!self.entries[ei].ran) || self.entries[ei].slow
        if want {
            s.prog_file = self.scratch(".prog")
            w.field("progress", s.prog_file)
        }

        w.end_object()

        self.lives[k].t.send(w.out)
        if self.lives[k].t.closed {
            self.live_lost(k, "exited")
            return false
        }

        if want && self.progress_ok {
            self.seq += 1
            s.progress = f"kals-index-{self.seq}"
            var cw = JsonWriter()
            cw.begin_object()
            cw.field("token", s.progress)
            cw.end_object()
            self.request_with(M_WORK_DONE_PROGRESS_CREATE, cw.out)
            var m = self.entries[ei].files.size() as i64
            if m > 0 {
                self.progress(s.progress, "begin", f"0/{m}", 0)
            } else {
                self.progress(s.progress, "begin", Path::filename_of(self.entries[ei].entry), -1)
            }
        } else if want {
            self.say(MSG_LOG, "indexing " + self.entries[ei].entry)
        }

        self.entries[ei].live_changed.clear()
        self.entries[ei].dirty   = false
        self.entries[ei].running = true
        self.lives[k].sent.push_back(s)
        self.trace(f"live send entry={self.entries[ei].entry} rev={s.rev} id={s.id}")
        return true
    }

    /// The worker of child \p k died or hung: its requests are dropped and
    /// the entry's next run is a process, so this revision still gets its
    /// results (and a crash that the text causes is reported by that run).
    fn live_lost(self, k: usize, const why: string) {
        var entry = self.lives[k].entry
        self.live_stop_(k)
        self.lives[k].restarts += 1
        self.lives[k].skip_once = true
        self.trace("live worker " + why + " entry=" + entry)
        if self.lives[k].restarts >= LIVE_MAX_RESTARTS {
            self.lives[k].failed = true
            self.say(MSG_WARNING, "live index worker keeps failing: " + entry + " is analysed by a process per run for the rest of the session")
        }

        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].entry == entry {
                self.entries[i].running      = false
                self.entries[i].dirty        = true
                self.entries[i].live_pending = 0
            }
        }
    }

    /// Takes every child's answers.
    fn live_read(self) {
        for var k: usize = 0; k < self.lives.size(); ++k {
            if self.lives[k].pid < 0 {
                continue
            }

            while (self.lives[k].pid >= 0) && self.lives[k].t.wait(0) {
                self.live_answer(k, self.lives[k].t.take())
            }

            if (self.lives[k].pid >= 0) && self.lives[k].t.closed {
                self.live_lost(k, "exited")
            }
        }
    }

    fn live_answer(self, k: usize, const msg: string) {
        var d = JsonDoc()
        if !d.parse(msg) {
            return
        }

        var id = d.get_int(d.root, "id")
        var at = usize::MAX
        for var q: usize = 0; q < self.lives[k].sent.size(); ++q {
            if self.lives[k].sent[q].id == id {
                at = q
            }
        }

        if at == usize::MAX {
            return
        }

        // More answers come under this id while files are queued.
        var bg      = d.get_bool(d.root, "bg")
        var pending = d.get_int(d.root, "pending")
        var more    = d.get_bool(d.root, "ok") && (pending > 0)
        self.lives[k].sent[at].draining = more
        self.lives[k].sent[at].ms       = now_ms()
        var s = self.lives[k].sent[at]
        if !more {
            var rest: [LiveSent]
            for var q: usize = 0; q < self.lives[k].sent.size(); ++q {
                if q != at {
                    rest.push_back(self.lives[k].sent[q])
                }
            }

            self.lives[k].sent = rest
        } else {
            self.lives[k].sent[at].progress  = ""
            self.lives[k].sent[at].prog_file = ""
        }

        var ptoken = s.progress
        s.progress = ""
        self.live_progress_end_(&s)

        var ei = usize::MAX
        for var i: usize = 0; i < self.entries.size(); ++i {
            if self.entries[i].entry == self.lives[k].entry {
                ei = i
            }
        }

        if (!ptoken.empty()) && ((ei == usize::MAX) || (!d.get_bool(d.root, "ok"))) {
            self.progress(ptoken, "end", "", -1)
            ptoken = ""
        }

        if d.get_bool(d.root, "superseded") {
            self.garbage.push_back(s.out)
            self.trace(f"live superseded id={id}")
            return
        }

        // A slice's snapshot is a file of its own; a slice that changed
        // nothing a snapshot holds sends none.
        var out = d.get_str(d.root, "out")
        // Nor is a slice installed over something newer: a process run of
        // a later text (a buffer that stopped parsing while files were
        // queued) that is in flight, or has landed. Its snapshot is of the
        // text before that run's, and installing it would put the older
        // result, and the older revision, back.
        var newer = false
        if bg && (ei != usize::MAX) {
            newer = self.entries[ei].has_snap && (s.rev < self.entries[ei].snap_rev)
            for var q: usize = 0; q < self.jobs.size(); ++q {
                if (self.jobs[q].kind == JOB_INDEX()) && (self.jobs[q].entry == ei) {
                    newer = true
                }
            }
        }

        if newer && (!out.empty()) {
            self.garbage.push_back(out)
            out = ""
        }

        if bg && out.empty() && d.get_bool(d.root, "ok") && (ei != usize::MAX) {
            self.entries[ei].live_pending = pending as usize
            var nj = Job()
            nj.kind        = JOB_INDEX()
            nj.entry       = ei
            nj.rev         = s.rev
            nj.live        = true
            nj.l_mode      = d.get_str(d.root, "mode")
            nj.l_why       = d.get_str(d.root, "why")
            nj.l_rechecked = d.get_int(d.root, "rechecked") as usize
            nj.l_pending   = pending as usize
            self.analysed_(ei, &nj, 0)
            return
        }

        if out.empty() {
            out = s.out
        }

        if ei == usize::MAX {
            self.garbage.push_back(s.out)
            return // the project was reloaded under this request
        }

        if !d.get_bool(d.root, "ok") {
            // The command line was refused: the process run says so in
            // the words a user is shown, and the worker starts over.
            self.garbage.push_back(s.out)
            self.live_stop_(k)
            self.lives[k].skip_once  = true
            self.entries[ei].running = false
            self.entries[ei].dirty   = true
            return
        }

        self.lives[k].steps += 1
        var j = Job()
        j.kind        = JOB_INDEX()
        j.entry       = ei
        j.out         = out
        j.rev         = s.rev
        // A slice took what the worker says it took, not the time since
        // the request: `slow` is about how long an answer is waited for.
        j.started_ms  = if (bg) => (now_ms() - (d.get_int(d.root, "us") / 1000)) else => (s.ms)
        j.rooted      = true
        j.text_paths  = s.text_paths
        j.texts       = s.texts
        j.live        = true
        j.l_mode      = d.get_str(d.root, "mode")
        j.l_why       = d.get_str(d.root, "why")
        j.l_rechecked = d.get_int(d.root, "rechecked") as usize
        j.l_pending   = d.get_int(d.root, "pending") as usize
        var rooted = self.entries[ei].rooted
        self.entries[ei].rooted = true
        self.entries[ei].live_pending = pending as usize
        // A slice that re-checked an open buffer changed its rows with no
        // edit of its own: the editor is asked to draw it again, though
        // the revision is one a refresh already went out for.
        if bg && d.get_bool(d.root, "touched") {
            self.entries[ei].owe_refresh = true
            self.refreshed_rev = 0
        }

        var was_dirty = self.entries[ei].dirty
        self.finish_index(&j, 0)
        self.entries[ei].rooted = rooted
        self.garbage.push_back(out)
        // A change made since is still to be sent: a slice's result is of
        // the text before it.
        if was_dirty {
            self.entries[ei].dirty = true
        }
        if !ptoken.empty() {
            self.progress(ptoken, "end", "", -1)
        }

        // A newer request is still to be answered (one that is only
        // draining has been: its first tier is what was asked for).
        for var q: usize = 0; q < self.lives[k].sent.size(); ++q {
            if !self.lives[k].sent[q].draining {
                self.entries[ei].running = true
            }
        }

        // Recycled between requests once it has grown: a re-check keeps
        // the trees it replaced (Tuning.k).
        var rss: i64 = unsafe kals_child_rss_mb(self.lives[k].pid)
        if (self.lives[k].base_rss < 0) || (j.l_mode == "full") {
            self.lives[k].base_rss = rss
        }

        self.lives[k].rss     = rss
        self.lives[k].last_ms = now_ms()
        var rmb = d.get_int(d.root, "retiredMb")
        var rfi = d.get_int(d.root, "retiredFiles")
        self.trace(f"live done entry={self.lives[k].entry} id={id} mode={j.l_mode} rechecked={j.l_rechecked} pending={pending} rss={rss} MB retired={rfi} trees {rmb} MB")
        if (rss > 0) && self.lives[k].sent.empty()
            && (rss > (((self.lives[k].base_rss * LIVE_RSS_FACTOR_PCT) / 100) + LIVE_RSS_SLACK_MB)) {
            self.live_recycle_(k, ei)
        }
    }

    /// Restarts child \p k and has the new one check the graph at once, in
    /// the background: the entry goes on answering from the snapshot it
    /// has, which is of the same text, and the next edit usually finds the
    /// worker warm. (An edit that arrives before then waits for the rest
    /// of that check.)
    fn live_recycle_(self, k: usize, ei: usize) {
        self.trace(f"live worker recycled after {self.lives[k].steps} steps, {self.lives[k].rss} MB (first check {self.lives[k].base_rss} MB)")
        self.live_stop_(k)
        self.lives[k].rss = -1
        var running = self.entries[ei].running
        var dirty   = self.entries[ei].dirty
        var slow    = self.entries[ei].slow
        // Not shown as progress: nothing the user asked for is waiting.
        self.entries[ei].slow = false
        var ran = self.entries[ei].ran
        if self.live_send(ei) && (self.live_waiting_(k) > 0) {
            self.entries[ei].running = running
            self.entries[ei].dirty   = dirty
        }

        self.entries[ei].slow = slow
        self.entries[ei].ran  = ran
    }

    /// Once a loop turn: answers, a request past its time, and an entry
    /// whose live check has outlasted a request's patience (slow, as a
    /// run's is: what is parked on it is answered from what there is).
    fn live_watch(self) {
        self.live_read()
        var now = now_ms()
        for var k: usize = 0; k < self.lives.size(); ++k {
            // Grown, and the editor quiet: restart it now, while nobody
            // waits for it (Tuning.k, LIVE_RSS_IDLE_PCT).
            if (self.lives[k].pid >= 0) && self.lives[k].sent.empty() && (self.lives[k].rss > 0)
                && (self.lives[k].base_rss > 0) && ((now - self.last_change_ms) > LIVE_IDLE_RECYCLE_MS)
                && ((now - self.lives[k].last_ms) > LIVE_IDLE_RECYCLE_MS)
                && (self.lives[k].rss > (((self.lives[k].base_rss * LIVE_RSS_IDLE_PCT) / 100) + LIVE_RSS_SLACK_MB)) {
                for var i: usize = 0; i < self.entries.size(); ++i {
                    if (self.entries[i].entry == self.lives[k].entry) && (!self.entries[i].dirty)
                        && (!self.entries[i].running) && self.entries[i].ran {
                        self.live_recycle_(k, i)
                        break
                    }
                }

                continue
            }

            if (self.lives[k].pid < 0) || self.lives[k].sent.empty() {
                continue
            }

            // The count of checked files, as report_progress reads a run's.
            for var q: usize = 0; q < self.lives[k].sent.size(); ++q {
                if self.lives[k].sent[q].progress.empty() {
                    continue
                }

                var text: string = ""
                if !LinkFS::read(self.lives[k].sent[q].prog_file, &text) {
                    continue
                }

                var n: i64 = 0
                for var c: usize = 0; c < text.size(); ++c {
                    if (text[c] >= 48) && (text[c] <= 57) {
                        n = (n * 10) + ((text[c] - 48) as i64)
                    }
                }

                if n == self.lives[k].sent[q].prog_n {
                    continue
                }

                self.lives[k].sent[q].prog_n = n
                self.progress(self.lives[k].sent[q].progress, "report", f"{n} files", -1)
            }

            var waited = now - self.lives[k].sent[0].ms
            if self.lives[k].sent[0].draining {
                continue // answered; its slices are not waited for
            }

            if waited > LIVE_TIMEOUT_MS {
                self.say(MSG_WARNING, "live index worker timed out: " + self.lives[k].entry + " is analysed by a process this time")
                self.live_lost(k, "timed out")
                continue
            }

            if waited > SLOW_RUN_MS {
                for var i: usize = 0; i < self.entries.size(); ++i {
                    if (self.entries[i].entry == self.lives[k].entry) && (!self.entries[i].slow) {
                        self.entries[i].slow = true
                        self.retry_parked(false)
                    }
                }
            }
        }
    }
}
