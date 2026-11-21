/// --- The Kairo Project ------------------ Preprocessor/WaveExecutor.k --- ///
///
///   Runs a DepGraph in dependency waves on the thread pool.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "functional"
ffi "c++" import "Native/SmallFunction.hh"

import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::DiagSink::DiagEngineVBase
import Diagnostic::Engine::{
    DiagCapture,
    DiagEngine,
}
import Location::SourceManager::SourceManager
import Preprocessor::DepScanner::{
    DepGraph,
    sorted_fids,
}
import Resolution::ModulePath::ModulePath
import Threading::ThreadPool::ThreadPool

pub class WaveExecutor {
    priv var _pool: *ThreadPool
    /// The last run's countdown: fid -> deps not yet walked. A copy of the
    /// graph's in_degree, so the graph keeps the scan's answer (an in-place
    /// decrement would make 0 mean both "ready" and "dispatched", and a
    /// second run over the same graph would see every file as a
    /// root). What is left above 0 after a run is what stranded() reports.
    priv var _pending: {u32: i32}

    fn WaveExecutor(self, pool: *ThreadPool) {
        self._pool = pool
    }

    /// Runs waves until no fid is ready.
    ///
    /// ### Parameters
    /// - `graph`: the dep graph (read only; the countdown is _pending)
    /// - `task_fn`: called once per fid with (fid, mod_path)
    ///   MUST be thread-safe: multiple calls run concurrently
    ///
    /// ### Returns
    /// how many fids were dispatched. Fewer than the graph holds
    /// means some never became ready -- a cycle in the graph -- and
    /// the caller must say so: those files were never walked.
    /// `diag` non-null: each task's diagnostics are held in a sink of its
    /// own (DiagCapture) and drained into `diag` when its wave is done, in
    /// the wave's dispatch order, each file's in source order. The files of
    /// one wave walk side by side, and reported straight to the engine they
    /// interleaved in the order they happened to finish, so which import
    /// error printed first, and which ones an error limit kept, changed
    /// from run to run. The order is the graph's alone: the waves
    /// already follow each other, and a wave's files go in the order its
    /// ready list holds them. Drained per wave, not at the end, so a long
    /// walk is not silent until its last file.
    fn run(self,
           graph:   *DepGraph,
           task_fn: fn(u32, ModulePath) -> void,
           diag:    unsafe *DiagEngine    = &null,
           sm:      unsafe *SourceManager = &null) -> usize {
        self._pending = graph->in_degree.copy()
        var ready             = graph->roots()
        var dispatched: usize = 0

        while ready.size() > 0 {
            dispatched += ready.size()
            var sinks: [unsafe *BufferedDiagSink]
            for fid in ready {
                var mod_path = graph->mod_paths[fid].copy()
                var sink: unsafe *BufferedDiagSink = &null
                if diag != &null {
                    sink = unsafe (@create BufferedDiagSink() as unsafe *BufferedDiagSink)
                    sinks.push(sink)
                }

                self._pool->enqueue(
                    kairo::SmallFunction<64>(
                        fn () |fid, mod_path, *task_fn, sink| {
                            if sink == &null {
                                cxx::std::invoke(*task_fn, fid, mod_path)
                                return
                            }

                            var _cap = DiagCapture(
                                unsafe (sink as unsafe *DiagEngineVBase),
                            )

                            cxx::std::invoke(*task_fn, fid, mod_path)
                        },
                    ),
                    1,
                )
            }

            // drain this wave - worker_loop decrements group 1 after each task
            self._pool->wait_group(1)
            for var i: usize = 0; i < sinks.size(); ++i {
                sinks[i]->drain_into(diag, sm)
                if sinks[i] != &null {
                    @destroy unsafe (sinks[i] as *BufferedDiagSink)
                }
            }

            // compute next wave
            var next: [u32]
            for fid in ready {
                for dependent in sorted_fids(graph->rdeps[fid]) {
                    self._pending[dependent] -= 1
                    if self._pending[dependent] == 0 {
                        next.push(dependent)
                    }
                }
            }

            ready = next
        }

        return dispatched
    }

    /// after run(): `fid` never became ready (a dependency of it was
    /// never walked), so it was never dispatched.
    fn stranded(self, fid: u32) -> bool {
        var left = self._pending.get(fid)
        return left != null && *left > 0
    }
}
