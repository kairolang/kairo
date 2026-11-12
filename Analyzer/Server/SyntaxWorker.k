/// --- The Kairo Project ---------------- Analyzer/Server/SyntaxWorker.k --- ///
///
///   The persistent syntax worker (LanguageServer.md section 11, item 2a):
///   one `kals --worker --syntax-server` process for the session, fed each
///   edited buffer over a pipe on the turn of the change, with no debounce.
///   A process per pass (Diagnostics.k start_syntax) is the fallback: on a
///   platform without the pipe shim, for a pass whose worker died or hung,
///   and for the rest of a session in which it keeps dying.
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
import Index::Snapshot::SK_OK
import Index::WorkerKeys::*
import Protocol::*
import Tuning::*
import WorkerArgs::*
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
import Server::LiveIndex::*

extend Server {
    /// The loop's wait: true when an editor message is buffered (take() it).
    /// While a syntax request is in flight the worker's answer pipe is in the
    /// same poll, so its answer is taken the moment it is written, not on the
    /// next idle tick (IDLE_WAIT_MS).
    fn wait_any(self, ms: i32) -> bool {
        // The pipes worth waking for: the syntax worker's while a pass is
        // in flight, and each live index worker's while it owes an answer.
        var fds: [i32; 30]
        var n: i32 = 0
        var syn = self.syn.busy()
        if syn {
            fds[0] = self.syn.t.fd_in
            n = 1
        }

        var live = false
        for var k: usize = 0; (k < self.lives.size()) && (n < 30); ++k {
            if (self.lives[k].pid >= 0) && (!self.lives[k].sent.empty()) {
                fds[n as usize] = self.lives[k].t.fd_in
                n += 1
                live = true
            }
        }

        if n == 0 {
            return self.t.wait(ms)
        }

        if self.t.wait(0) {
            return true
        }

        var bits: i32 = unsafe kals_pollv(unsafe &fds[0], n, ms)
        if bits >= 2 {
            if syn {
                self.syntax_read()
            }

            if live {
                self.live_read()
            }
        }

        if (bits > 0) && ((bits & 1) != 0) {
            return self.t.wait(0)
        }

        return false
    }

    /// Starts the worker if it is not running. False when it cannot run (the
    /// fallback path takes over).
    fn syntax_spawn(self) -> bool {
        if self.syn.failed() {
            return false
        }

        if self.syn.running() {
            return true
        }

        // '\n'-separated words: the shim's argv (kals_child_spawn).
        var words = self.exe + "\n" + WA_WORKER + "\n" + WA_SYNTAX_SERVER + "\n" + WA_END
        var to_child: i32 = -1
        var from_child: i32 = -1
        var pid: i64 = -1
        if !self.debug_refuse_("syntax-server") {
            pid = unsafe kals_child_spawn(unsafe &words.raw()[0], words.size() as u64, unsafe &to_child, unsafe &from_child)
        }

        if pid < 0 {
            self.syn.state = SynWorker::Failed
            self.say(MSG_LOG, "syntax worker unavailable here: syntax passes run as a process each")
            return false
        }

        self.syn.pid    = pid
        self.syn.passes = 0
        self.syn.state  = SynWorker::Idle
        self.syn.t      = Transport()
        self.syn.t.fd_in  = from_child
        self.syn.t.fd_out = to_child
        self.trace(f"syntax worker started pid={pid}")
        return true
    }

    fn syntax_stop(self) {
        if !self.syn.running() {
            return
        }

        unsafe kals_child_stop(self.syn.pid, self.syn.t.fd_out, self.syn.t.fd_in)
        self.syn.pid   = -1
        self.syn.state = SynWorker::NotRunning
    }

    /// The worker died or hung with a request in flight: restart it, and run
    /// that buffer's pass as a process so this keystroke still gets its
    /// diagnostics.
    fn syntax_lost(self, const why: string) {
        var path = self.syn.path
        var was  = self.syn.busy()
        self.syntax_stop()
        self.syn.restarts += 1
        self.say(MSG_WARNING, "syntax worker " + why + ": restarted; this pass runs as a process")
        if self.syn.restarts >= SYNTAX_SERVER_MAX_RESTARTS {
            self.syn.state = SynWorker::Failed
            self.say(MSG_WARNING, "syntax worker keeps failing: a process per pass for the rest of the session")
        } else {
            self.syntax_spawn() // now, so its start overlaps the fallback pass
        }

        if !was {
            return
        }

        var di = self.docs.index_of_path(path)
        if di == usize::MAX {
            return
        }

        // Due again (syntax_kick marked it started): the process pass
        // below, or, if that cannot start now, the next worker or the
        // fallback loop, takes it.
        self.docs.docs[di].syn.abandon()
        if self.running(JobKind::Syntax) < MAX_SYNTAX_PASSES {
            self.start_syntax(di)
        }
    }

    /// Feeds the worker the next edited buffer, when it is idle. One request
    /// in flight: a buffer edited meanwhile is sent when the answer lands,
    /// so a newer revision supersedes every one typed during the pass.
    fn syntax_kick(self) {
        if self.syn.failed() || self.syn.busy() {
            return
        }

        var di = usize::MAX
        for var k: usize = 0; k < self.docs.docs.size(); ++k {
            if self.docs.docs[k].syn_due() {
                di = k
                break
            }
        }

        if di == usize::MAX {
            return
        }

        if !self.syntax_spawn() {
            return
        }

        self.docs.docs[di].sync()
        self.syn_seq += 1
        var w = JsonWriter()
        w.begin_object()
        w.field_int(RQ_ID, self.syn_seq)
        w.field(RQ_FILE, self.docs.docs[di].path)
        w.field(RQ_TEXT, self.docs.docs[di].text)
        w.end_object()

        self.syn.state   = SynWorker::Busy
        self.syn.id      = self.syn_seq
        self.syn.path    = self.docs.docs[di].path
        self.syn.rev     = self.rev
        self.syn.sent_ms = now_ms()
        self.docs.docs[di].syn.begin(self.docs.docs[di].changed_at)
        self.syn.t.send(w.out)
        if self.syn.t.closed {
            self.syntax_lost("exited")
        }
    }

    /// Takes the worker's answers.
    fn syntax_read(self) {
        while self.syn.t.wait(0) {
            self.syntax_answer(self.syn.t.take())
        }

        if self.syn.t.closed && self.syn.running() {
            self.syntax_lost("exited")
        }
    }

    fn syntax_answer(self, const msg: string) {
        var d = JsonDoc()
        if (!d.parse(msg)) || (d.get_int(d.root, RP_ID) != self.syn.id) || (!self.syn.busy()) {
            return // superseded inside the worker, or a reply to a lost request
        }

        self.syn.state   = SynWorker::Idle
        self.syn.passes += 1
        var took = now_ms() - self.syn.sent_ms
        var di   = self.docs.index_of_path(self.syn.path)
        self.trace(f"syntax done (worker) rev={self.syn.rev} {took} ms " + self.syn.path)
        if di != usize::MAX {
            self.docs.docs[di].syn.finish()
            // A stale answer is dropped (land_syntax), and the pass for the
            // newer text starts now (syntax_kick). This is also the publish
            // coalescing: with one pass in flight, typing faster than a
            // pass publishes nothing until it pauses for one pass's time.
            if d.get_bool(d.root, SK_OK) {
                self.land_syntax(di, self.syn.rev, &d, true)
            }
        }

        // Recycled between requests (a pass leaks about 0.4 MB).
        var rss: i64 = unsafe kals_child_rss_mb(self.syn.pid)
        if (self.syn.passes >= SYNTAX_SERVER_MAX_PASSES) || (rss > SYNTAX_SERVER_MAX_RSS_MB) {
            self.trace(f"syntax worker recycled after {self.syn.passes} passes, {rss} MB")
            self.syntax_stop()
            self.syntax_spawn()
        }
    }

    /// Once a loop turn: a request past its time is a hung worker.
    fn syntax_watch(self) {
        if self.syn.busy() && ((now_ms() - self.syn.sent_ms) > SYNTAX_SERVER_TIMEOUT_MS) {
            self.syntax_lost("timed out")
            return
        }

        if self.syn.busy() {
            self.syntax_read()
        }
    }
}
