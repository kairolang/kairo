/// --- The Kairo Project ----------------------- Threading/ThreadPool.k --- ///
///
///   ThreadPool: a work-stealing pool that runs grouped tasks.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/SmallFunction.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KThread.hh" // spawn_pool_workers, thread_pool_local_qid
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "thread"
ffi "c++" import "vector"
ffi "c++" import "array"
ffi "c++" import "cstring"
ffi "c++" import "utility"
ffi "c++" import "chrono"
ffi "c++" import "atomic"

import Support::EvalHash::{
    FNV1A64_OFFSET,
    FNV1A64_PRIME,
    GOLDEN_RATIO_MIX,
}
import Support::Timer::Timer
import Support::Tuning::WORKER_STACK_BYTES
import Threading::PartitionQueue::{
    DEFAULT_QUEUE_SIZE,
    PartitionQueue,
}
import Threading::Task::Task
import std::io

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
pub class ThreadPool {
    /// C++ threading alias for std::thread.
    type Thread = cxx::std::#thread

    priv var _count:  usize                                    = 0
    priv var _queues: cxx::std::vector<unsafe *PartitionQueue>
    priv var _groups: cxx::std::array<kairo::std::Atomic<u64>, 256> = cxx::std::array<kairo::std::Atomic<u64>, 256>()
    priv var _active:       kairo::std::Atomic<bool>  = kairo::std::Atomic<bool>(true)
    priv var _live_workers: kairo::std::Atomic<usize> = kairo::std::Atomic<usize>(0)

    /// Idle workers PARK here rather than spinning.
    ///
    /// A worker with nothing to do parks; alternating _thread_pause() and
    /// cthread_yield() would have every worker burn a core for the whole run
    /// of a serial workload. On an M-series package that is stolen thermal
    /// budget, so it does not merely waste cores, it downclocks the one core
    /// that is working and contaminates every measurement taken.
    ///
    /// _queued is the number of tasks pushed but not yet claimed. It is the
    /// park predicate, and it is a separate counter from _groups: _groups[g]
    /// counts tasks not yet FINISHED (what wait_group waits on), which stays
    /// positive while a task runs and would keep every worker awake for the
    /// duration of the last task.
    priv var _queued: kairo::std::Atomic<i64> = kairo::std::Atomic<i64>(0)
    /// Parking is an atomic wait on _epoch, not a mutex + condition variable.
    /// A mutex and condvar would lock/unlock and notify on every enqueue
    /// whether or not anyone slept; under musl a condvar wake costs several
    /// futex calls (per-waiter futex, then the mutex is re-taken), which
    /// doubles kernel time against glibc.
    /// atomic::wait / notify_one is one futex each way on every libc (libc++
    /// calls the kernel itself), and _sleepers lets a producer skip the wake
    /// entirely while every worker is busy.
    ///
    /// The lost-wakeup argument, all seq_cst:
    ///   worker:   _sleepers++ ; e = _epoch ; check _queued / _active ; wait(e)
    ///   producer: _queued++   ; if _sleepers > 0 { _epoch++ ; notify_one }
    /// If the producer reads _sleepers == 0, the worker's increment comes
    /// later in the total order, so its _queued check sees the task. If it
    /// reads > 0 it bumps _epoch: a worker that read e before the bump either
    /// finds _epoch != e in wait() or is woken; one that read it after sees
    /// the task in _queued.
    priv var _sleepers: kairo::std::Atomic<u32> = kairo::std::Atomic<u32>(0)
    priv var _epoch:    kairo::std::Atomic<u32> = kairo::std::Atomic<u32>(0)

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
    fn ThreadPool(self) {
        var n: usize = ((Self::Thread::hardware_concurrency()) as usize)
        if n == 0 {
            n = 1
        }

        self._count = n
        self._queues.reserve(n)

        for gi in (0 as usize)..256 {
            self._groups[gi].store(0, kairo::std::MemoryOrder::relaxed)
        }

        // Single-threaded: no workers. enqueue() runs inline.
        if n == 1 {
            kairo::Logger::info(
                kairo::Logger::Stage::ThreadPool,
                "ThreadPool: single-threaded (inline) mode",
            )

            return // skip thread spawning entirely
        }

        self._live_workers.store(n, kairo::std::MemoryOrder::release)

        // Allocate all queues first before any thread can index into _queues
        for _ in (0 as usize)..n {
            self._queues.push_back(
                unsafe (@create PartitionQueue(DEFAULT_QUEUE_SIZE) as unsafe *PartitionQueue),
            )
        }

        // Now spawn threads all queues are guaranteed present. Each runs
        // worker_loop(i) on a detached native thread with a 32 MiB stack;
        // the pthread / CreateThread calls are in Native/KThread.hh.
        kairo::spawn_pool_workers(unsafe &self, self._count, WORKER_STACK_BYTES)

        kairo::Logger::info(
            kairo::Logger::Stage::ThreadPool,
            f"ThreadPool: initialized {self._count} workers",
        )
    }

    fn ThreadPool(self, n: usize) {
        if n == 0 {
            n = 1
        }

        self._count = n
        self._queues.reserve(n)

        for gi in (0 as usize)..256 {
            self._groups[gi].store(0, kairo::std::MemoryOrder::relaxed)
        }

        // Single-threaded: no workers. enqueue() runs inline.
        if n == 1 {
            kairo::Logger::info(
                kairo::Logger::Stage::ThreadPool,
                "ThreadPool: single-threaded (inline) mode",
            )

            return // skip thread spawning entirely
        }

        self._live_workers.store(n, kairo::std::MemoryOrder::release)

        // Allocate all queues first before any thread can index into _queues
        for _ in (0 as usize)..n {
            self._queues.push_back(
                unsafe (@create PartitionQueue(DEFAULT_QUEUE_SIZE) as unsafe *PartitionQueue),
            )
        }

        // Now spawn threads all queues are guaranteed present. Each runs
        // worker_loop(i) on a detached native thread with a 32 MiB stack;
        // the pthread / CreateThread calls are in Native/KThread.hh.
        kairo::spawn_pool_workers(unsafe &self, self._count, WORKER_STACK_BYTES)

        kairo::Logger::info(
            kairo::Logger::Stage::ThreadPool,
            f"ThreadPool: initialized {self._count} workers",
        )
    }

    ///
    /// \brief Destructor that ensures proper shutdown.
    ///
    /// \details Invokes `shutdown()` to terminate all threads and clean up
    ///     resources. Safe to call multiple times; subsequent calls are noops.
    ///
    /// \see shutdown
    ///
    fn op finally (self) {
        self.shutdown()
    }

    inline static fn fnv1a64_bytes(const tid: kairo::std::Thread::id) -> u64 {
        var h: u64 = FNV1A64_OFFSET

        eval TID_SIZE: usize = sizeof(cxx::std::#thread::id)

        var buf: [u8; TID_SIZE]
        cxx::std::memcpy(unsafe &buf[0], unsafe &tid, TID_SIZE)

        for var i: usize = 0; i < TID_SIZE; ++i {
            h = (h ^ buf[i]) * FNV1A64_PRIME
        }

        return h
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
    pub inline fn enqueue(self, _fn: kairo::SmallFunction<64>, group: u8 = 0) {
        if !self._active.load(kairo::std::MemoryOrder::relaxed) {
            return
        }

        // Single-threaded pool: run inline on the calling thread. No queue, no
        // worker handoff - the task is fully complete before enqueue returns, so
        // group counters never need to move and wait_group is a no-op.
        if self._count == 1 {
            _fn()
            return
        }

        // increment BEFORE task is visible to any worker
        self._groups[group].fetch_add(1, kairo::std::MemoryOrder::relaxed)

        // This thread's queue, picked once from its id and cached in a
        // thread_local (Native/KThread.hh) shared by every pool.
        var local_qid: unsafe *usize = kairo::thread_pool_local_qid()
        if *local_qid == usize::MAX {
            var tid = cxx::std::this_thread::get_id()
            *local_qid = ((Self::fnv1a64_bytes(tid) % (self._count as u64)) as usize)
        }

        var qid = *local_qid

        var task = Task()
        task._fn    = kairo::SmallFunction<64>(cxx::std::move(_fn))
        task._group = group

        // push takes ref, task stays valid across failed attempts
        if self._queues[qid]->push(&task) {
            self.signal_one()
            return
        }

        var alt = (qid + 1) % self._count
        if self._queues[alt]->push(&task) {
            self.signal_one()
            return
        }

        kairo::Logger::warn(
            kairo::Logger::Stage::ThreadPool,
            f"ThreadPool::enqueue: qid={qid} full, spinning (group={group})",
        )

        while !self._queues[qid]->push(&task) {
            kairo::thread_pause()
        }

        self.signal_one()
    }

    /// \brief publishes one queued task and wakes a parked worker, if any.
    ///
    /// \details No wake while no worker is parked: the common case under load,
    ///          and the one that cost a mutex round trip per task before. Why
    ///          skipping it cannot lose a wakeup is at _epoch.
    priv inline fn signal_one(self) {
        self._queued.fetch_add(1)
        if self._sleepers.load() > 0 {
            self._epoch.fetch_add(1)
            self._epoch.notify_one()
        }
    }

    ///
    /// \brief Waits for completion of all tasks within a specific group.
    ///
    /// \param group Group ID to wait for.
    ///
    /// \details
    /// Spins briefly (a short wait resolves without a syscall), then blocks
    ///     on the group's counter itself: an atomic wait, woken by the task
    ///     that takes it to zero (_task_done). It does not sleep-poll: that
    ///     would nap for as long as the group runs and log a "stalled"
    ///     warning every cycle of a long join (the codegen fan-out).
    ///
    ///     No lost wakeup: libc++'s wait(v) re-checks the value after
    ///     registering as a waiter, and the decrement to zero always
    ///     notifies. The counter may also move between nonzero values (a
    ///     task finishing, another enqueued) without a wake; the waiter only
    ///     cares about zero, which always wakes it, and it re-checks after
    ///     every wake.
    ///
    /// \warning
    ///   - Blocking call. Avoid long waits on the main thread.
    ///
    pub inline fn wait_group(self, group: u8) {
        for var spins: u32 = 0; spins < 10000; ++spins {
            if self._groups[group].load(kairo::std::MemoryOrder::acquire) == 0 {
                return
            }

            kairo::thread_pause()
        }

        while true {
            var v = self._groups[group].load(kairo::std::MemoryOrder::acquire)
            if v == 0 {
                return
            }

            self._groups[group].wait(v, kairo::std::MemoryOrder::acquire)
        }
    }

    /// \brief one task of \p group is finished: the counter drops, and the
    ///        last one wakes whoever waits on the group (wait_group).
    ///
    /// \details acq_rel: release so the waiter sees the task's writes, and
    ///          the notify comes after the decrement it announces. notify_all
    ///          costs no syscall while nobody waits (libc++ counts waiters).
    priv inline fn _task_done(self, group: u8) {
        if self._groups[group].fetch_sub(1, kairo::std::MemoryOrder::acq_rel) == 1 {
            self._groups[group].notify_all()
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
    pub inline fn wait_all(self) {
        for gi in (0 as u32)..256 {
            self.wait_group((gi as u8))
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
        var expected = true

        if !self._active.compare_exchange_strong(&expected, false) {
            return
        }

        kairo::Logger::info(
            kairo::Logger::Stage::ThreadPool,
            f"ThreadPool::shutdown: joining {self._count} workers total_pending={self.get_total_pending_tasks()}",
        )

        // _active is already false. Wake everyone that is parked, or they
        // never observe it and the join below spins forever. The bump is
        // unconditional: a worker that read _epoch before it finds it changed
        // in wait(), one that reads it after sees _active false (see _epoch).
        self._epoch.fetch_add(1)
        self._epoch.notify_all()

        while self.get_total_pending_tasks() > 0 {
            cxx::std::this_thread::sleep_for(cxx::std::chrono::microseconds(100))
        }

        // One notify_all is enough: a worker always re-checks _active after
        // announcing itself in _sleepers, so a worker still running a task at the
        // broadcast will see the flag on its next trip round and exit without
        // ever parking again.
        while self._live_workers.load(kairo::std::MemoryOrder::acquire) > 0 {
            kairo::thread_pause()
        }

        for *q in self._queues {
            @destroy unsafe (*q as *PartitionQueue)
        }

        self._queues.clear()
        kairo::Logger::info(kairo::Logger::Stage::ThreadPool, "ThreadPool::shutdown: complete")
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
        var        task:      Task
        var unsafe *q              = self._queues[id]
        var        rng_state: u64  = (((id + 1) as u64)) * GOLDEN_RATIO_MIX

        inline fn next_rand(state: unsafe *u64) -> usize {
            *state = *state ^ *state >> 12
            *state = *state ^ *state << 25
            *state = *state ^ *state >> 27

            return (*state * 0x2545f4914f6cdd1d >> 32) as usize
        }

        while true {
            if q->pop(&task) {
                self._queued.fetch_sub(1, kairo::std::MemoryOrder::acquire)
                task._fn()

                self._task_done(task._group)
                continue
            }

            var   found         = false
            const BATCH:  usize = 4
            const STRIDE: usize = 3

            for var k: usize = 0; k < self._count; k += STRIDE {
                var target = (id + next_rand(unsafe &rng_state) + k) % self._count

                if target == id {
                    continue
                }

                for var n: usize = 0; n < BATCH; ++n {
                    if self._queues[target]->steal(&task) {
                        self._queued.fetch_sub(1, kairo::std::MemoryOrder::acquire)
                        task._fn()
                        self._task_done(task._group)

                        found = true

                        break
                    }
                }

                if found {
                    break
                }
            }

            if found {
                continue
            }

            // Nothing to run. Park (the protocol is at _epoch).
            self._sleepers.fetch_add(1)
            var e = self._epoch.load()

            // A task published between the failed steal above and the
            // _sleepers increment is visible here; one published after it
            // bumps _epoch, so the wait below returns at once.
            if self._queued.load() > 0 {
                self._sleepers.fetch_sub(1)
                continue
            }

            // Exit only with the queues drained. Testing _active as the loop
            // condition let a worker leave with tasks still queued, after
            // which shutdown()'s drain of get_total_pending_tasks() could
            // never reach zero.
            if !self._active.load() {
                self._sleepers.fetch_sub(1)
                break
            }

            // A spurious wakeup just re-runs pop/steal, which is correct.
            self._epoch.wait(e)
            self._sleepers.fetch_sub(1)
        }

        self._live_workers.fetch_sub(1, kairo::std::MemoryOrder::release)
    }

    ///
    /// \brief Returns true if all tasks in a group have completed.
    ///
    /// \param group Group ID to check.
    /// \return `true` if all tasks have finished, otherwise `false`.
    ///
    fn is_completed(self, group: u8) -> bool {
        return self._groups[group].load(kairo::std::MemoryOrder::acquire) == 0
    }

    ///
    /// \brief Checks whether the pool is active.
    ///
    /// \return `true` if threads are still processing or accepting work.
    ///
    pub fn is_active(self) -> bool {
        return self._active.load(kairo::std::MemoryOrder::acquire)
    }

    ///
    /// \brief Retrieves the total number of worker threads.
    ///
    /// \return Worker thread count.
    ///
    pub fn get_thread_count(self) -> usize {
        return self._count
    }

    ///
    /// \brief Retrieves the number of pending tasks for a specific group.
    ///
    /// \param group Group ID.
    /// \return Number of pending tasks.
    ///
    fn get_pending_tasks(self, group: u8) -> u64 {
        return ((self._groups[group].load(kairo::std::MemoryOrder::acquire)))
    }

    ///
    /// \brief Retrieves the total number of pending tasks across all groups.
    ///
    /// \return Aggregate pending task count.
    ///
    fn get_total_pending_tasks(self) -> u64 {
        var total: u64 = 0

        for gi in (0 as usize)..256 {
            total += ((self._groups[gi].load(kairo::std::MemoryOrder::acquire)))
        }

        return total
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
        if self._count == 1 {
            return
        }

        var barrier: kairo::std::Atomic<usize> = kairo::std::Atomic<usize>(0)
        kairo::Logger::debug(
            kairo::Logger::Stage::ThreadPool,
            f"ThreadPool::warmup: {self._count} threads spins={spins}",
        )

        fn heat_task(barrier: unsafe *kairo::std::Atomic<usize>, iterations: i32) {
            var x: i64 = 1

            for var j: i32 = 0; j < iterations; ++j {
                x = (x * 3 + j) % 7919
            }

            barrier->fetch_add(1, cxx::std::memory_order::release)

            while barrier->load(
                cxx::std::memory_order::acquire,
            ) < (Self::Thread::hardware_concurrency() as usize) {
                kairo::thread_pause()
            }

            if x == 42 {
                io::println("")
            }
        }

        for var i: usize = 0; i < self._count; ++i {
            // the barrier is shared, never copied (atomics are not copyable)
            self.enqueue(
                kairo::SmallFunction<64>(
                    fn() |heat_task, *barrier, spins| {
                        heat_task(unsafe (barrier as unsafe *kairo::std::Atomic<usize>), spins)
                    },
                ),
                i as u8,
            )
        }

        while barrier.load(kairo::std::MemoryOrder::acquire) < self._count {
            kairo::thread_pause()
        }

        kairo::Logger::debug(kairo::Logger::Stage::ThreadPool, "ThreadPool::warmup: complete")

        kairo::thread_pause()
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
pub fn Test() -> i32 {
    io::println("=== Kairo ThreadPool Benchmark ===")
    var total_timer = Timer("Total test duration")

    var pool             = ThreadPool()
    var total_tasks: i32
    var groups:      i32

    /// a bare `{}` block scopes the Timer, so it reports on exit.
    {
        var startup = Timer("ThreadPool startup")
        total_tasks = 4000
        groups      = 4
        pool.warmup()
    }

    io::println(f"Spawning {total_tasks} tasks across {groups} groups...")

    fn heavy_task() {
        var acc: i64 = 1

        for var j: i32 = 1; j <= 2500; ++j {
            acc = (acc * 3 + j) % 7919
        }

        if acc == 0 {
            io::println("") // prevent optimization (never runs)
        }
    }

    {
        var enqueue_timer = Timer("Enqueue phase")

        for var i: i32 = 0; i < total_tasks; ++i {
            var g: u8 = ((i % groups) as u8)
            pool.enqueue(kairo::SmallFunction<64>(heavy_task), g)
        }
    }

    for var g: i32 = 0; g < groups; ++g {
        var t = Timer(f"Group {g} completion")
        pool.wait_group(g as u8)
    }

    var sync_timer = Timer("Final synchronization")
    pool.shutdown()

    return 0
}
