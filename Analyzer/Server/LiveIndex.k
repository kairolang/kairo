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
///   lists, for the revision a worker died or timed out on, and for the rest
///   of a session in which it keeps dying.
///
///   A BUFFER THAT DOES NOT PARSE is not a run of any kind. Its text is sent
///   to the worker to be TRIED AND NOT KEPT (`aside`, Index/LiveWorker.k): a
///   copy of the worker re-checks that file alone, with the function bodies
///   its syntax errors are in dropped when that is all that is wrong with
///   it, and ends. The worker's graph keeps the last text of the buffer
///   that parsed, so the entry's index stays the last good one (answered
///   through LineShift on the lines the edits left alone), every file that
///   imports it keeps its rows, and the next text that parses is one
///   ordinary re-check from there. What the copy found is the buffer's
///   diagnostics until it changes again (Document::side_diags).
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
import Index::Snapshot::{
    SK_DIAG,
    SK_DIAGNOSTICS,
    SK_OK,
    SK_PATH,
}
import Index::WorkerKeys::*
import Protocol::*
import Resolution::ModulePath::kairo_dot_ext
import Tuning::*
import WorkerArgs::*
import Json::{
    JSON_NONE,
    JsonDoc,
    JsonWriter,
}
import JsonRpc::Transport
import std::io
import Server::Completion::*
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
        var words = self.exe + "\n" + WA_WORKER + "\n" + WA_INDEX_SERVER + "\n" + WA_CWD + "\n" + self.entries[ei].dir
        words += "\n" + WA_ROOT + "\n" + self.project.dir + "\n" + WA_END
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

        // A new worker counts its steps from one: it sends every table.
        self.entries[ei].tb_have = 0
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

        // A completion it was asked for is a process's now.
        var asks = self.lives[k].asks
        self.lives[k].asks.clear()
        for var q: usize = 0; q < asks.size(); ++q {
            self.live_ask_falls_back_(&asks[q])
        }
    }

    /// The completion \p a goes to a process of its own (or, when its
    /// entry is gone, is answered with nothing).
    fn live_ask_falls_back_(self, a: *LiveAsk) {
        self.garbage.push_back(a->out)
        var ei = self.entry_by_id(a->entry_id)
        if (ei == usize::MAX) || (self.session == Session::ShutDown) {
            self.garbage.push_back(a->marked)
            self.respond(a->lsp_id, "{\"isIncomplete\":true,\"items\":[]}")
            return
        }

        self.trace("live completion falls back to a process: " + a->path)
        self.complete_by_run_(ei, a->lsp_id, a->path, a->member, a->edit, a->marked, a->t0_us)
    }

    /// \brief asks entry \p ei's live worker for a completion: the marked
    ///        buffer \p mpath is tried aside (LiveWorker.k), the file alone,
    ///        and the items are what its walk found at the marker. False
    ///        when there is no worker to ask: the caller starts a process.
    ///
    /// \details Not while the entry's first check is still to land (the
    ///          worker has no graph to copy; a process is as fast), nor of
    ///          a worker that is being restarted. The worker answers
    ///          between two steps of whatever it is doing, a queue of
    ///          importers included, which it then goes on with.
    fn live_complete_(self,
                      ei:          usize,
                      const id:    string,
                      const path:  string,
                      member:      bool,
                      const edit:  string,
                      const mpath: string,
                      t0_us:       i64) -> bool {
        if (!self.live_on) || self.entries[ei].adhoc {
            return false
        }

        var k = self.live_of(ei)
        if (k == usize::MAX) || self.lives[k].failed || (self.lives[k].pid < 0) || (!self.entries[ei].ran)
            || (!self.entries[ei].holds(path)) {
            return false
        }

        var a = LiveAsk()
        self.live_seq += 1
        a.id       = self.live_seq
        a.lsp_id   = id
        a.entry_id = self.entries[ei].id
        a.path     = path
        a.marked   = mpath
        a.out      = self.scratch(".json")
        a.edit     = edit
        a.member   = member
        a.ms       = now_ms()
        a.t0_us    = t0_us

        var w = JsonWriter()
        w.begin_object()
        w.field_int(RQ_ID, a.id)
        w.field_bool(RQ_ONLY, true)
        w.field(RQ_ASIDE_OUT, a.out)
        w.key(RQ_ASIDE)
        w.begin_array()
        w.begin_object()
        w.field(RQ_PATH, path)
        w.field(RQ_FILE, mpath)
        w.end_object()
        w.end_array()
        w.end_object()
        self.lives[k].t.send(w.out)
        if self.lives[k].t.closed {
            self.garbage.push_back(a.out)
            return false
        }

        self.lives[k].asks.push_back(a)
        self.trace(f"live completion sent id={a.id} " + path)
        return true
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

        // A changed buffer that does not parse is not sent to be kept (see
        // the head of this file). The syntax pass says whether it does, a
        // few milliseconds after the change; it is waited for, briefly.
        var now = now_ms()
        for var b: usize = 0; b < self.docs.docs.size(); ++b {
            if self.entries[ei].ran && (!self.entries[ei].holds(self.docs.docs[b].path)) {
                continue
            }

            if !self.docs.docs[b].path.ends_with(".k") {
                continue
            }

            var known = self.docs.docs[b].syn.current(self.docs.docs[b].changed_at)
            if (!known) && (self.docs.docs[b].changed_at > 0) && ((now - self.docs.docs[b].changed_ms) < LIVE_SYNTAX_WAIT_MS) {
                return true
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

        var aside_files: [string]
        var w = JsonWriter()
        w.begin_object()
        w.field_int(RQ_ID, s.id)
        w.field_int(RQ_HAVE, self.entries[ei].tb_have as i64)
        w.field(RQ_OUT, s.out)
        w.key(RQ_OPEN)
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

            // Does not parse: this text is tried aside, and the text the
            // worker KEEPS for the file is the one the entry's index read
            // (the last that parsed), sent as any buffer is so that a
            // worker started since holds it too. When no such text is
            // known the worker has, and keeps, the disk's.
            if path.ends_with(".k") && self.docs.docs[b].syn.current(self.docs.docs[b].changed_at)
                && (!self.docs.docs[b].syn.parsed) {
                if self.docs.docs[b].idx_entry == self.entries[ei].entry {
                    if (self.docs.docs[b].held_rev != self.docs.docs[b].idx_rev) || self.docs.docs[b].held_tmp.empty() {
                        if !self.docs.docs[b].held_tmp.empty() {
                            self.garbage.push_back(self.docs.docs[b].held_tmp)
                        }

                        self.docs.docs[b].held_tmp = self.scratch(kairo_dot_ext())
                        self.docs.docs[b].held_rev = self.docs.docs[b].idx_rev
                        LinkFS::write(self.docs.docs[b].held_tmp, self.docs.docs[b].idx_text)
                    }

                    w.begin_object()
                    w.field(RQ_PATH, path)
                    w.field(RQ_FILE, self.docs.docs[b].held_tmp)
                    w.end_object()
                    s.text_paths.push_back(path)
                    s.texts.push_back(self.docs.docs[b].idx_text)
                }

                s.aside_paths.push_back(path)
                aside_files.push_back(self.docs.docs[b].tmp_path)
                continue
            }

            w.begin_object()
            w.field(RQ_PATH, path)
            w.field(RQ_FILE, self.docs.docs[b].tmp_path)
            w.end_object()
            s.text_paths.push_back(path)
            s.texts.push_back(self.docs.docs[b].text)
        }

        w.end_array()
        if !s.aside_paths.empty() {
            s.aside_out = self.scratch(".json")
            w.field(RQ_ASIDE_OUT, s.aside_out)
            w.key(RQ_ASIDE)
            w.begin_array()
            for var q: usize = 0; q < s.aside_paths.size(); ++q {
                w.begin_object()
                w.field(RQ_PATH, s.aside_paths[q])
                w.field(RQ_FILE, aside_files[q])
                w.end_object()
            }

            w.end_array()
            self.trace(f"live aside entry={self.entries[ei].entry}: {s.aside_paths.size()} buffer(s) that do not parse")
        }

        w.key(RQ_CHANGED)
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
            w.field(RQ_PROGRESS, s.prog_file)
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
            cw.field(K_TOKEN, s.progress)
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

        var id = d.get_int(d.root, RP_ID)

        // A completion's: the items are in what the worker's copy wrote.
        if d.get_bool(d.root, RP_ONLY) {
            var rest: [LiveAsk]
            var mine = LiveAsk()
            var have = false
            for var q: usize = 0; q < self.lives[k].asks.size(); ++q {
                if self.lives[k].asks[q].id == id {
                    mine = self.lives[k].asks[q]
                    have = true
                } else {
                    rest.push_back(self.lives[k].asks[q])
                }
            }

            if !have {
                return // past its time: a process has it
            }

            self.lives[k].asks = rest
            // The copy has to have CHECKED the marked buffer: one it could
            // not make, or one that refused the file (unchecked, none), has
            // no items, and a process finds them.
            var how = self.live_side_states_(mine.out)
            if (d.get_str(d.root, RP_ASIDE) != ASIDE_OK) || ((how != AS_CHECKED) && (how != AS_PARTIAL)) {
                self.live_ask_falls_back_(&mine)
                return
            }

            var cj = Job()
            cj.kind     = JobKind::Complete
            cj.entry_id = mine.entry_id
            cj.out      = mine.out
            cj.id       = mine.lsp_id
            cj.path     = mine.path
            cj.member   = mine.member
            cj.edit     = mine.edit
            cj.how      = HOW_LIVE
            cj.t0_us    = mine.t0_us
            self.trace(f"live completion done id={id} {now_ms() - mine.ms} ms")
            self.finish_complete(&cj, 0)
            self.garbage.push_back(mine.out)
            self.garbage.push_back(mine.marked)
            return
        }

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
        var bg      = d.get_bool(d.root, RP_BG)
        var pending = d.get_int(d.root, RP_PENDING)
        var more    = d.get_bool(d.root, RP_OK) && (pending > 0)
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

        if (!ptoken.empty()) && ((ei == usize::MAX) || (!d.get_bool(d.root, RP_OK))) {
            self.progress(ptoken, "end", "", -1)
            ptoken = ""
        }

        if (!bg) && (!s.aside_out.empty()) {
            self.garbage.push_back(s.aside_out) // read below, in this call
        }

        if d.get_bool(d.root, RP_SUPERSEDED) {
            self.garbage.push_back(s.out)
            self.trace(f"live superseded id={id}")
            return
        }

        // A slice's snapshot is a file of its own; a slice that changed
        // nothing a snapshot holds sends none.
        var out = d.get_str(d.root, RP_OUT)
        // Nor is a slice installed over something newer: a process run of
        // a later text (a buffer that stopped parsing while files were
        // queued) that is in flight, or has landed. Its snapshot is of the
        // text before that run's, and installing it would put the older
        // result, and the older revision, back.
        var newer = false
        if bg && (ei != usize::MAX) {
            newer = self.entries[ei].has_snap && (s.rev < self.entries[ei].snap_rev)
            for var q: usize = 0; q < self.jobs.size(); ++q {
                if (self.jobs[q].kind == JobKind::Index) && (self.jobs[q].entry_id == self.entries[ei].id) {
                    newer = true
                }
            }
        }

        if newer && (!out.empty()) {
            self.garbage.push_back(out)
            out = ""
        }

        if bg && out.empty() && d.get_bool(d.root, RP_OK) && (ei != usize::MAX) {
            self.entries[ei].live_pending = pending as usize
            var nj = Job()
            nj.kind        = JobKind::Index
            nj.entry_id    = self.entries[ei].id
            nj.rev         = s.rev
            nj.live        = true
            nj.l_mode      = d.get_str(d.root, RP_MODE)
            nj.l_why       = d.get_str(d.root, RP_WHY)
            nj.l_rechecked = d.get_int(d.root, RP_RECHECKED) as usize
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

        if !d.get_bool(d.root, RP_OK) {
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
        j.kind        = JobKind::Index
        j.entry_id    = self.entries[ei].id
        j.out         = out
        j.rev         = s.rev
        // A slice took what the worker says it took, not the time since
        // the request: `slow` is about how long an answer is waited for.
        j.started_ms  = if (bg) => (now_ms() - (d.get_int(d.root, RP_US) / 1000)) else => (s.ms)
        j.rooted      = true
        j.text_paths  = s.text_paths
        j.texts       = s.texts
        j.live        = true
        j.l_mode      = d.get_str(d.root, RP_MODE)
        j.l_why       = d.get_str(d.root, RP_WHY)
        j.l_rechecked = d.get_int(d.root, RP_RECHECKED) as usize
        j.l_pending   = d.get_int(d.root, RP_PENDING) as usize
        j.held_paths  = s.aside_paths
        // The buffers tried aside that are still the text that was sent.
        var tried: [string]
        if (!bg) && (d.get_str(d.root, RP_ASIDE) == ASIDE_OK) {
            for var q: usize = 0; q < s.aside_paths.size(); ++q {
                var tdi = self.docs.index_of_path(s.aside_paths[q])
                if (tdi != usize::MAX) && (self.docs.docs[tdi].changed_at <= s.rev) {
                    tried.push_back(s.aside_paths[q])
                }
            }
        }

        if !tried.empty() {
            j.l_aside = self.live_side_states_(s.aside_out)
        }

        var rooted = self.entries[ei].rooted
        self.entries[ei].rooted = true
        self.entries[ei].live_pending = pending as usize
        // A slice that re-checked an open buffer changed its rows with no
        // edit of its own: the editor is asked to draw it again, though
        // the revision is one a refresh already went out for.
        if bg && d.get_bool(d.root, RP_TOUCHED) {
            self.entries[ei].owe_refresh = true
            self.refreshed_rev = 0
        }

        var was_dirty = self.entries[ei].dirty
        self.finish_index(&j, 0)
        self.live_side_(ei, &tried, s.aside_out)
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
        var rmb = d.get_int(d.root, RP_RETIRED_MB)
        var rfi = d.get_int(d.root, RP_RETIRED_FILES)
        self.trace(f"live done entry={self.lives[k].entry} id={id} mode={j.l_mode} rechecked={j.l_rechecked} pending={pending} rss={rss} MB retired={rfi} trees {rmb} MB")
        if (rss > 0) && self.lives[k].sent.empty()
            && (rss > (((self.lives[k].base_rss * LIVE_RSS_FACTOR_PCT) / 100) + LIVE_RSS_SLACK_MB)) {
            self.live_recycle_(k, ei)
        }
    }

    /// The states of an aside result, in order, comma-joined (`partial`,
    /// `unchecked`, ...): what `$/kals/analysed` says of it.
    fn live_side_states_(self, const out: string) -> string {
        var text: string = ""
        var doc = JsonDoc()
        var all: string = ""
        if (!LinkFS::read(out, &text)) || (!doc.parse(text)) {
            return all
        }

        var st = doc.first(doc.get(doc.root, AS_STATES))
        while st != JSON_NONE() {
            if !all.empty() {
                all += ","
            }

            all += doc.get_str(st, AS_STATE)
            st = doc.next(st)
        }

        return all
    }

    /// What the worker's copy found for the buffers \p tried (LiveWorker.k,
    /// live_aside_copy, in \p out) becomes their diagnostics, until they
    /// change again.
    fn live_side_(self, ei: usize, tried: *const [string], const out: string) {
        if tried->empty() {
            return
        }

        var text: string = ""
        var doc = JsonDoc()
        if (!LinkFS::read(out, &text)) || (!doc.parse(text)) || (!doc.get_bool(doc.root, SK_OK)) {
            return
        }

        for var q: usize = 0; q < tried->size(); ++q {
            var di = self.docs.index_of_path((*tried)[q])
            if di == usize::MAX {
                continue
            }

            var state: string = ""
            var st = doc.first(doc.get(doc.root, AS_STATES))
            while st != JSON_NONE() {
                if doc.get_str(st, SK_PATH) == (*tried)[q] {
                    state = doc.get_str(st, AS_STATE)
                }

                st = doc.next(st)
            }

            // Nothing was found out about it: the syntax pass's errors and
            // the last run's stand, as without a live worker.
            if (state != AS_CHECKED) && (state != AS_PARTIAL) && (state != AS_UNCHECKED) {
                continue
            }

            var diags: string = ""
            var n: usize = 0
            var x = doc.first(doc.get(doc.root, SK_DIAGNOSTICS))
            while x != JSON_NONE() {
                if doc.get_str(x, SK_PATH) == (*tried)[q] {
                    if n > 0 {
                        diags += ","
                    }

                    diags += doc.dump(doc.get(x, SK_DIAG))
                    n += 1
                }

                x = doc.next(x)
            }

            self.docs.docs[di].side_has   = true
            self.docs.docs[di].side_at    = self.docs.docs[di].changed_at
            self.docs.docs[di].side_state = state
            self.docs.docs[di].side_diags = diags
            self.docs.docs[di].side_n     = n
            self.trace(f"live aside landed: {state}, {n} diagnostics " + (*tried)[q])
            self.publish_doc(ei, di)
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

            // A completion the worker has not got to: a process, now.
            if (self.lives[k].pid >= 0) && (!self.lives[k].asks.empty()) && ((now - self.lives[k].asks[0].ms) > LIVE_ASK_TIMEOUT_MS) {
                var late = self.lives[k].asks[0]
                var rest: [LiveAsk]
                for var q: usize = 1; q < self.lives[k].asks.size(); ++q {
                    rest.push_back(self.lives[k].asks[q])
                }

                self.lives[k].asks = rest
                self.live_ask_falls_back_(&late)
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
