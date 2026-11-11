/// --- The Kairo Project --------------------- Analyzer/Server/Workers.k --- ///
///
///   Worker processes: argv, launch, reap, and installing an index run's snapshot.
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
import Server::Scheduling::*
import Server::Server::*
import Server::SignatureHelp::*
import Server::Structure::*
import Server::TextUtil::*
import Server::Tokens::*
import Server::SyntaxWorker::*

extend Server {
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
        // `--root` indexes every file under the project, and the worker
        // drops those rows again when the graph is wide (WIDE_INDEX_LIMIT):
        // on the kals graph (418 files) walking them was 2.2 s of CPU in a
        // 10 s run. A graph last seen wide is run without it; a run that
        // finds it narrow again is rerun with it (finish_index).
        self.entries[ei].rooted = !(self.entries[ei].ran && (self.entries[ei].files.size() > WIDE_INDEX_LIMIT))
        if self.entries[ei].rooted {
            argv.push_back("--root")
            argv.push_back(self.project.dir)
        }

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

        if (!self.entries[ei].ran) || (self.entries[ei].files.size() > WIDE_INDEX_LIMIT) {
            return false
        }

        for var i: usize = 0; i < self.jobs.size(); ++i {
            if self.jobs[i].kind != JOB_INDEX() {
                continue
            }

            var o = self.jobs[i].entry
            if (o >= self.entries.size()) || (!self.entries[o].ran) || (self.entries[o].files.size() > WIDE_INDEX_LIMIT) {
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
        j.rooted = self.entries[ei].rooted

        // The texts this run reads, as worker_argv chose them (it synced
        // every buffer): the same test, so a buffer it did not overlay, read
        // from the disk if at all, is never recorded as indexed.
        for var b: usize = 0; b < self.docs.docs.size(); ++b {
            if self.entries[ei].ran && (!self.entries[ei].holds(self.docs.docs[b].path)) {
                continue
            }

            j.text_paths.push_back(self.docs.docs[b].path)
            j.texts.push_back(self.docs.docs[b].text)
        }
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
            self.request_with(M_WORK_DONE_PROGRESS_CREATE, cw.out)
            var m = self.entries[ei].files.size() as i64
            if m > 0 {
                self.progress(j.progress, "begin", f"0/{m}", 0)
            } else {
                self.progress(j.progress, "begin", Path::filename_of(self.entries[ei].entry), -1)
            }
        } else if want {
            self.say(MSG_LOG, "indexing " + self.entries[ei].entry)
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
            } else if j.kind == JOB_HEADER() {
                self.finish_header_(&j, done.ReturnCode)
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
        self.notify(M_KALS_ANALYSED, aw.out)
    }

    fn finish_index(self, j: *Job, rc: i32) {
        var ei = j->entry
        if ei >= self.entries.size() {
            return // the project was reloaded under this run
        }

        // Killed by a later change (touch): no result, no crash report, and
        // `slow` keeps what the last whole run measured. touch left the
        // entry dirty, so the loop starts it again after the debounce.
        if j->stale {
            self.entries[ei].running = false
            self.entries[ei].dirty   = true
            self.trace(f"index dropped entry={self.entries[ei].entry} rev={j->rev}")
            return
        }

        self.entries[ei].running  = false
        self.entries[ei].ran      = true
        self.entries[ei].done_rev = j->rev

        // Re-judged every run: an entry that got fast again (a release
        // build of the server, a smaller graph) goes back to exact answers.
        var took = now_ms() - j->started_ms
        self.entries[ei].slow = took > SLOW_RUN_MS
        self.trace(f"index done entry={self.entries[ei].entry} rc={rc} rev={j->rev}")

        // What installing a snapshot costs (section 11, scenario 2): traced
        // per run as `install`.
        var t0 = now_us()
        var text: string = ""
        var doc = JsonDoc()
        var read_ok = LinkFS::read(j->out, &text)
        var t1 = now_us()
        var ok  = read_ok && doc.parse(text) && doc.get_bool(doc.root, "ok")
        var t2 = now_us()
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

            self.say(MSG_WARNING, why)
            self.analysed_(ei, j, rc)
            self.retry_parked(false)
            return
        }

        // The first result for an entry, and any run slow enough to be felt,
        // is worth a line; a run per keystroke on a small project is not.
        if (!self.entries[ei].has_snap) || (took > SLOW_RUN_MS) {
            var nd = doc.count(doc.get(doc.root, "diagnostics"))
            var nf = doc.count(doc.get(doc.root, "deps"))
            self.say(MSG_LOG, f"analysed {self.entries[ei].entry}: {nf} files, {nd} diagnostics, {took} ms")
        }

        if (!j->rooted) && doc.get_bool(doc.root, "wide") {
            self.entries[ei].dirty = true // narrow again: the files under the root were not walked
        }

        self.entries[ei].snap     = doc
        self.entries[ei].has_snap = true
        self.entries[ei].snap_rev = j->rev
        var t3 = now_us()
        var t4 = t3
        if (doc.count(doc.get(doc.root, "files")) > 0) && self.index_installs(ei, &doc) {
            self.entries[ei].idx     = doc
            self.entries[ei].has_idx = true
            self.entries[ei].idx_rev = j->rev
            t4 = now_us()
            self.index_cache(ei)

            // Only a buffer this index has rows for: one the graph never
            // loaded keeps whatever another entry recorded.
            for var q: usize = 0; q < j->texts.size(); ++q {
                var tdi = self.docs.index_of_path(j->text_paths[q])
                if (tdi != usize::MAX) && (self.file_node(ei, j->text_paths[q]) != JSON_NONE()) {
                    self.docs.docs[tdi].set_indexed(j->texts[q], j->rev, self.entries[ei].entry)
                }
            }
        }

        var t5 = now_us()

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

        var t6 = now_us()
        self.publish(ei)
        var t7 = now_us()
        var tm = doc.get(doc.root, "timing")
        self.trace(f"install bytes={text.size()} read_us={t1 - t0} parse_us={t2 - t1} snap_copy_us={t3 - t2} idx_copy_us={t4 - t3} cache_us={t5 - t4} publish_us={t7 - t6} total_us={t7 - t0} worker=" + doc.dump(tm))
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
                self.request(M_SEMANTIC_TOKENS_REFRESH)
            }

            if self.refresh_inlays {
                self.request(M_INLAY_HINT_REFRESH)
            }
        }
    }
}
