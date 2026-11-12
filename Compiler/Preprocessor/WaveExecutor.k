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
ffi "c++" import "map"
ffi "c++" import "vector"
ffi "c++" import "Native/SmallFunction.hh"

import Preprocessor::DepScanner::DepGraph
import Resolution::ModulePath::ModulePath
import Threading::ThreadPool::ThreadPool

pub class WaveExecutor {
    priv var _pool: *ThreadPool
    /// The last run's countdown: fid -> deps not yet walked. A copy of the
    /// graph's in_degree, so the graph keeps the scan's answer (the old
    /// in-place decrement made 0 mean both "ready" and "dispatched", and a
    /// second run over the same graph would have seen every file as a
    /// root). What is left above 0 after a run is what stranded() reports.
    priv var _pending: cxx::std::map<u32, i32>

    fn WaveExecutor(self, pool: *ThreadPool) {
        self._pool = pool
    }

    /// \brief Runs waves until no fid is ready.
    /// \param graph        the dep graph (read only; the countdown is _pending)
    /// \param task_fn      called once per fid with (fid, mod_path)
    ///                     MUST be thread-safe: multiple calls run concurrently
    /// \returns how many fids were dispatched. Fewer than the graph holds
    ///          means some never became ready -- a cycle in the graph -- and
    ///          the caller must say so: those files were never walked.
    fn run(self, graph: *DepGraph, task_fn: fn(u32, ModulePath) -> void) -> usize {
        self._pending = graph->in_degree
        var ready             = graph->roots()
        var dispatched: usize = 0

        while ready.size() > 0 {
            dispatched += ready.size()
            for fid in ready {
                var mod_path = graph->mod_paths[fid]

                self._pool->enqueue(
                    kairo::SmallFunction<64>(
                        fn () |fid, mod_path, *task_fn| {
                            cxx::std::invoke(*task_fn, fid, mod_path)
                        },
                    ),
                    1,
                )
            }

            // drain this wave - worker_loop decrements group 1 after each task
            self._pool->wait_group(1)

            // compute next wave
            var next = cxx::std::vector<u32>()
            for fid in ready {
                for dependent in graph->rdeps[fid] {
                    self._pending[dependent] -= 1
                    if self._pending[dependent] == 0 {
                        next.push_back(dependent)
                    }
                }
            }

            ready = next
        }

        return dispatched
    }

    /// \brief after run(): \p fid never became ready (a dependency of it was
    ///        never walked), so it was never dispatched.
    fn stranded(self, fid: u32) -> bool {
        var it = self._pending.find(fid)
        return it != self._pending.end() && it->second > 0
    }
}
