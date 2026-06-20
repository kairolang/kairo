/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/SmallFunction.hh";
ffi "c++" import "Native/Types.hh";

import Threading::Task::*;
import Threading::PartitionQueue::*;
import Support::Timer::*;

///
/// \class ThreadPool
///
/// \brief A high-performance work-stealing thread pool for parallel
///        task execution.
///
/// \details
/// The `ThreadPool` class implements a lock-free, cache-aligned work-stealing
///     design optimized for minimal contention and consistent task throughput
///     across heterogeneous systems. Each worker maintains a per-thread
///     partitioned queue from which tasks are locally dequeued and, when idle,
///     stolen by other threads in randomized batches.
///
/// Tasks are represented as small callable objects (`SmallFunction<64>`) and
///     can be grouped via a numeric identifier for synchronization purposes.
///     The pool supports dynamic task submission, group-based waiting, and
///     graceful shutdown.
///
/// The design prioritizes deterministic startup, cache coherency, and
///     predictable shutdown semantics for long-running parallel workloads.
///
/// \warning
///   - The number of threads defaults to the hardware concurrency level but
///     can be explicitly set (minimum of 1).
///   - Each partitioned queue has a fixed capacity (default 16384 tasks).
///   - Tasks are copy-disabled and move-only to ensure locality and prevent
///     accidental duplication.
///   - The pool must be explicitly shut down to join all threads and release
///     resources.
///   - The implementation relies on C++11 atomics and threading primitives.
///
/// \see PartitionQueue, Task, wait_group, enqueue, shutdown, warmup
///
class ThreadPool {
    /// C++ threading alias for std::thread, the alias is in a __inline_cpp
    /// block to avoid stage(0) parser issues with the 'thread' keyword.
    inline "c++" {
        using Thread = libcxx::thread;
        static constexpr size_t DEFAULT_QUEUE_SIZE = 1 << 14;
    }

    priv var _count:        usize = 0;
    priv var _queues:       vec::<own::<PartitionQueue>>;
    priv var _groups:       array::<std::Atomic::<u64>, 256> = array::<std::Atomic::<u64>, 256>();
    priv var _active:       std::Atomic::<bool>              = std::Atomic::<bool>(true);
    priv var _live_workers: std::Atomic::<usize>             = std::Atomic::<usize>(0);

    ///
    /// \brief Constructs and initializes a thread pool.
    ///
    /// \param n Number of threads to create (defaults to hardware concurrency).
    ///
    /// \details
    /// Allocates one partitioned queue per worker, initializes task groups, and
    ///     spawns all worker threads immediately. Each worker enters an
    ///     internal execution loop awaiting tasks or performing random steal
    ///     attempts when idle.
    ///
    /// \warning
    ///   - If `n == 0`, one worker is forced to ensure valid operation.
    ///   - Threads start immediately upon construction.
    ///
    /// \see worker_loop
    ///
    fn ThreadPool(self, n: usize = Thread::hardware_concurrency()) {
        if n == 0 {
            n = 1;
        }

        self._count = n;
        self._queues.reserve(n);

        for gi in range::<usize>(0, 256) {
            self._groups[gi].store(0, std::MemoryOrder::relaxed);
        }

        // Single-threaded: no workers. enqueue() runs inline.
        if n == 1 {
            Logger::info(Logger::Stage::ThreadPool, "ThreadPool: single-threaded (inline) mode");
            return;  // skip thread spawning entirely
        }

        self._live_workers.store(n, std::MemoryOrder::release);

        // Allocate all queues first before any thread can index into _queues
        for _ in range::<usize>(0, n) {
            var q = std::create_unique::<PartitionQueue>(DEFAULT_QUEUE_SIZE);
            self._queues.push_back(q.release());
        }

        // Now spawn threads all queues are guaranteed present
        const eval if defined(__APPLE__) || defined(__linux__) {
            inline "c++" {
            for (size_t i = 0; i < _count; ++i) {
                pthread_attr_t attr;
                pthread_attr_init(&attr);
                pthread_attr_setstacksize(&attr, 64UL * 1024 * 1024);
                pthread_t tid;
                auto* arg = new libcxx::pair<ThreadPool*, size_t>(this, i);
                pthread_create(&tid, &attr, [](void* raw) -> void* {
                    auto* p = static_cast<libcxx::pair<ThreadPool*, size_t>*>(raw);
                    p->first->worker_loop(p->second);
                    delete p;
                    return nullptr;
                }, arg);
                pthread_attr_destroy(&attr);
                pthread_detach(tid);
            }
            }
        } else if defined(_WIN32) {
            inline "c++" {
            for (size_t i = 0; i < _count; ++i) {
                auto* arg = new libcxx::pair<ThreadPool*, size_t>(this, i);
                    HANDLE h = CreateThread(nullptr, 64UL * 1024 * 1024,
                        [](LPVOID raw) -> DWORD {
                            auto* p = static_cast<libcxx::pair<ThreadPool*, size_t>*>(raw);
                            p->first->worker_loop(p->second);
                            delete p;
                            return 0;
                        }, arg, STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
                    CloseHandle(h);
            }
            }
        }
        
        Logger::info(Logger::Stage::ThreadPool, f"ThreadPool: initialized {self._count} workers");
    }

    ///
    /// \brief Destructor that ensures proper shutdown.
    ///
    /// \details Invokes `shutdown()` to terminate all threads and clean up
    ///     resources. Safe to call multiple times; subsequent calls are noops.
    ///
    /// \see shutdown
    ///
    fn op delete (self) {
        self.shutdown();
    }

    inline static fn fnv1a64_bytes(const tid: ref!(std::Thread::id)) -> u64 {
        var h: u64 = 0xcbf29ce484222325;

        inline "c++" {
            static constexpr size_t TID_SIZE = sizeof(libcxx::thread::id);
        }

        var buf: std::Memory::buffer::<u8, TID_SIZE>;
        libcxx::memcpy(buf, &tid, TID_SIZE);

        for var i: usize = 0; i < TID_SIZE; ++i {
            h = (h ^ buf[i]) * 0x100000001b3;
        }

        return h;
    }

    ///
    /// \brief Schedules a callable for asynchronous execution.
    ///
    /// \param _fn Callable function (moved into queue).
    /// \param group Optional group ID for synchronization tracking.
    ///
    /// \details
    /// The function is enqueued in a pseudo-random queue using round-robin with
    ///     FNV-based hash mixing. If the selected queue is full, the task is
    ///     retried sequentially across all queues. Group counters are atomically
    ///     incremented on successful enqueue to enable completion tracking.
    ///
    /// \see wait_group, is_completed
    ///
    inline fn enqueue(self, _fn: SmallFunction::<64>, group: u8 = 0) {
        if !self._active.load(std::MemoryOrder::relaxed) { return; }

        // Single-threaded pool: run inline on the calling thread. No queue, no
        // worker handoff - the task is fully complete before enqueue returns, so
        // group counters never need to move and wait_group is a no-op.
        if self._count == 1 {
            _fn();
            return;
        }

        // increment BEFORE task is visible to any worker
        self._groups[group].fetch_add(1, std::MemoryOrder::relaxed);

        inline "c++" {
            thread_local size_t local_qid = static_cast<size_t>(-1);
        }

        if local_qid == static_cast::<usize>(-1) {
            var tid = libcxx::this_thread::get_id();
            local_qid = static_cast::<usize>(fnv1a64_bytes(tid) % self._count);
        }

        var qid = local_qid;

        var task = Task();
        task._fn    = std::Memory::move(_fn);
        task._group = group;

        // push takes ref, task stays valid across failed attempts
        if self._queues[qid]->push(task) { return; }

        var alt = (qid + 1) % self._count;
        if self._queues[alt]->push(task) { return; }

        Logger::warn(Logger::Stage::ThreadPool, f"ThreadPool::enqueue: qid={qid} full, spinning (group={group})");

        while !self._queues[qid]->push(task) {
            _thread_pause();
        }
    }

    ///
    /// \brief Waits for completion of all tasks within a specific group.
    ///
    /// \param group Group ID to wait for.
    ///
    /// \details
    /// Spins adaptively and yields progressively until the specified group
    ///     counter reaches zero. Uses a hybrid approach combining busy-wait,
    ///     micro-sleep, and periodic resets to balance responsiveness and CPU
    ///     efficiency.
    ///
    /// \warning
    ///   - Blocking call. Avoid long waits on the main thread.
    ///
    inline fn wait_group(self, group: u8) {
        var spins: u32 = 0;

        while self._groups[group].load(std::MemoryOrder::acquire) > 0 {
            if spins < 10000 {
                _thread_pause();
                ++spins;
            } else if spins < 20000 {
                libcxx::this_thread::sleep_for(libcxx::chrono::microseconds(8));
                ++spins;
            } else {
                libcxx::this_thread::sleep_for(libcxx::chrono::microseconds(50));
                spins = 0; // reset to check more frequently again
                Logger::warn(Logger::Stage::ThreadPool, f"ThreadPool::wait_group: group={group} stalled pending={self._groups[group].load(std::MemoryOrder::acquire)}");
            }
        }
    }

    ///
    /// \brief Waits for completion of all tasks across all groups.
    ///
    /// \details
    /// Iteratively invokes `wait_group` for each group ID from 0 to 255.
    ///
    /// \see wait_group
    ///
    inline fn wait_all(self) {
        for gi in range::<u32>(0, 256) {
            self.wait_group(gi);
        }
    }

    ///
    /// \brief Initiates an orderly shutdown of the thread pool.
    ///
    /// \details
    /// Gracefully terminates all worker threads after active tasks complete.
    ///     Joins all threads, deletes all queues, and clears internal state.
    ///     Subsequent calls are ignored once shutdown has begun.
    ///
    /// \see worker_loop, is_active
    ///
    fn shutdown(self) {
        var expected = true;

        if !self._active.compare_exchange_strong(expected, false) {
            return;
        }

        Logger::info(Logger::Stage::ThreadPool, f"ThreadPool::shutdown: joining {self._count} workers total_pending={self.get_total_pending_tasks()}");
        
        inline "c++" {
            while (get_total_pending_tasks() > 0) {
                libcxx::this_thread::sleep_for(libcxx::chrono::microseconds(100));
            }
        }

        while self._live_workers.load(std::MemoryOrder::acquire) > 0 {
            _thread_pause();
        }

        for q: ref!(*PartitionQueue) in self._queues {
            delete q;
        }

        self._queues.clear();
        Logger::info(Logger::Stage::ThreadPool, "ThreadPool::shutdown: complete");
    }

    ///
    /// \brief Main execution loop executed by each worker thread.
    ///
    /// \param id Worker thread index.
    ///
    /// \details
    /// Each worker dequeues tasks from its local queue, executes them, and
    ///     updates group counters. When the local queue is empty, it performs
    ///     randomized stealing in small batches across other queues. If no
    ///     tasks are found, threads engage in adaptive spinning and yielding to
    ///     prevent wasted CPU time.
    ///
    /// \note This function runs indefinitely until `_active` is set to false.
    ///
    fn worker_loop(self, id: usize) {
        var task:  Task;
        var spins: u32 = 0;
        var q = self._queues[id];
        var rng_state: u64 = (id + 1) * 0x9e3779b97f4a7c15;

        inline fn next_rand(state: *u64) -> usize {
            (*state) = (*state) ^ ((*state) >> 12);
            (*state) = (*state) ^ ((*state) << 25);
            (*state) = (*state) ^ ((*state) >> 27);

            return static_cast::<usize>(((*state) * 0x2545f4914f6cdd1d) >> 32);
        }

        while self._active.load(std::MemoryOrder::acquire) {
            if q->pop(&task) {
                task._fn();

                self._groups[task._group].fetch_sub(1, std::MemoryOrder::release);
                spins = 0;

                continue;
            }

            var   found = false;
            const BATCH:  usize = 4;
            const STRIDE: usize = 3;

            for var k: usize = 0; k < self._count; k += STRIDE {
                var target = (id + next_rand(&rng_state) + k) % self._count;

                if target == id {
                    continue;
                }

                for var n: usize = 0; n < BATCH; ++n {
                    if self._queues[target]->steal(&task) {
                        task._fn();
                        self._groups[task._group].fetch_sub(
                            1, std::MemoryOrder::release
                        );

                        found = true;
                        spins = 0;

                        break;
                    }
                }

                if found { break; }
            }

            if !found {
                if spins < 2000 {
                    _thread_pause();
                    ++spins;
                } else {
                    inline "c++" {
                        libcxx::this_thread::yield();
                    }
                    
                    spins = 0;
                }
            }
        }

        self._live_workers.fetch_sub(1, std::MemoryOrder::release);
    }

    ///
    /// \brief Returns true if all tasks in a group have completed.
    ///
    /// \param group Group ID to check.
    /// \return `true` if all tasks have finished, otherwise `false`.
    ///
    fn is_completed(self, group: u8) -> bool {
        return self._groups[group].load(std::MemoryOrder::acquire) == 0;
    }

    ///
    /// \brief Checks whether the pool is active.
    ///
    /// \return `true` if threads are still processing or accepting work.
    ///
    fn is_active(self) -> bool {
        return self._active.load(std::MemoryOrder::acquire);
    }

    ///
    /// \brief Retrieves the total number of worker threads.
    ///
    /// \return Worker thread count.
    ///
    fn get_thread_count(self) -> usize {
        return self._count;
    }

    ///
    /// \brief Retrieves the number of pending tasks for a specific group.
    ///
    /// \param group Group ID.
    /// \return Number of pending tasks.
    ///
    fn get_pending_tasks(self, group: u8) -> u64 {
        return self._groups[group].load(std::MemoryOrder::acquire);
    }

    ///
    /// \brief Retrieves the total number of pending tasks across all groups.
    ///
    /// \return Aggregate pending task count.
    ///
    fn get_total_pending_tasks(self) -> u64 {
        var total: u64 = 0;

        for gi in range::<usize>(0, 256) {
            total += self._groups[gi].load(std::MemoryOrder::acquire);
        }

        return total;
    }

    ///
    /// \brief Performs a CPU warmup routine to eliminate cold-start latency.
    ///
    /// \param spins Number of iterations for dummy computations.
    ///
    /// \details Executes synthetic spin tasks across all threads to ensure:
    ///   - Thread scheduling and CPU frequency ramp-up.
    ///   - L1/L2 cache warming for task dispatch structures.
    ///
    /// Threads synchronize via a barrier to ensure simultaneous readiness
    ///     before returning.
    ///
    /// \see enqueue
    ///
    fn warmup(self, spins: i32 = 1000000) {
        if self._count == 1 { return; }

        var barrier: std::Atomic::<usize> = std::Atomic::<usize>(0);
        Logger::debug(Logger::Stage::ThreadPool, f"ThreadPool::warmup: {self._count} threads spins={spins}");

        fn heat_task(barrier: *std::Atomic::<usize>, spins: i32) {
            var x: i64 = 1;

            for var j: i32 = 0; j < spins; ++j {
                x = (x * 3 + j) % 7919;
            }

            barrier->fetch_add(1, libcxx::memory_order::release);

            while barrier->load(libcxx::memory_order::acquire)
                < Thread::hardware_concurrency() {
                _thread_pause();
            }

            if x == 42 {
                std::print("");
            }
        }

        for var i: usize = 0; i < self._count; ++i {
            self.enqueue(fn() {
                heat_task(&barrier, spins);
            }, static_cast::<u8>(i));
        }

        while barrier.load(std::MemoryOrder::acquire) < self._count {
            _thread_pause();
        }

        Logger::debug(Logger::Stage::ThreadPool, "ThreadPool::warmup: complete");

        _thread_pause();
    }
}

///
/// \brief ThreadPool performance benchmark and validation entrypoint.
///
/// \return Always returns 0 on success.
///
/// \details
/// The `Test()` function initializes a thread pool, performs a warmup phase,
///     dispatches 4000 compute-heavy tasks across multiple groups, and measures
///     the total execution time across startup, enqueue, completion, and
///     synchronization phases. provides a reproducible benchmark for assessing
///     Pqueue contention, warm-start effectiveness, and task completion latency.
///
/// \see ThreadPool, Timer, wait_group, warmup
///
fn Test() -> i32 {
    std::print("=== Kairo ThreadPool Benchmark ===");
    var total_timer = Timer("Total test duration");

    var pool = ThreadPool();
    var total_tasks: i32;
    var groups:      i32;

    /// for some reason the stage(0) parser does not allow `{}` scoped blocks
    /// so we have to use __inline_cpp to create a scope for the Timer RAII
    /// object to work correctly.
    {
        var startup = Timer("ThreadPool startup");
        total_tasks = 4000;
        groups = 4;
        pool.warmup();
    }

    std::print(f"Spawning {total_tasks} tasks across {groups} groups...");

    fn heavy_task() {
        var acc: i64 = 1;

        for var j: i32 = 1; j <= 2500; ++j {
            acc = (acc * 3 + j) % 7919;
        }

        if acc == 0 {
            std::print(""); // prevent optimization (never runs)
        }
    }

    {
        var enqueue_timer = Timer("Enqueue phase");

        for var i: i32 = 0; i < total_tasks; ++i {
            var g: u8 = static_cast::<u8>(i % groups);
            pool.enqueue(heavy_task, g);
        }
    }

    for var g: i32 = 0; g < groups; ++g {
        var t = Timer(f"Group {g} completion");
        pool.wait_group(static_cast::<u8>(g));
    }

    var sync_timer = Timer("Final synchronization");
    pool.shutdown();

    return 0;
}
