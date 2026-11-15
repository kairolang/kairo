/// --- The Kairo Project ---------------------------- Native/Thread.hh --- ///
///
///   Thread-pool plumbing Kairo cannot spell: native thread creation with an
///   explicit stack size, a thread_local, and a cache-line-aligned queue cell.
///
///   WHY C++: pthread_create / CreateThread take a C callback, `thread_local`
///   and `alignas` have no Kairo spelling, and the cell needs a hand-written
///   move that relaxes through an atomic. ThreadPool and PartitionQueue
///   call it.
///
///   ODR: everything is a template or an inline function, and the one piece
///   of state (the per-thread queue id) is a function-local thread_local, so
///   there is one instance per thread program-wide however many TUs include
///   this.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KTHREAD_HH__
#define __KAIRO_NATIVE_KTHREAD_HH__

#include "Prelude.hh"
#include <atomic>
#include <exception>
#include <utility>

#if defined(_WIN32)
#include "Win32.hh"   // spawn_thread, run_on_thread; never <windows.h> here
#else
#include <pthread.h>
#endif

namespace kairo {

namespace native {

/// A pool worker cannot be started. The pool counts its workers before it
/// starts them and waits for every one of them at shutdown, so a missing
/// worker is a hang; the process ends here instead, saying why.
[[noreturn]] inline void worker_start_failed(usize index, usize count, const char *why) noexcept {
    ::std::fprintf(stderr, "error: cannot start worker thread %zu of %zu: %s\n",
                   static_cast<size_t>(index + 1), static_cast<size_t>(count), why);
    ::std::fflush(stderr);
    ::std::_Exit(1);
}

}  // namespace native

/// Starts \p count detached native threads, thread i running
/// `pool->worker_loop(i)`, each with a stack of \p stack_bytes
/// (Support/Tuning.k's WORKER_STACK_BYTES). Templated on the pool
/// so this header needs no declaration of ThreadPool, which is a Kairo
/// class; the pair handed to the thread is freed by the thread.
///
/// Every thread is started or the process ends (native::worker_start_failed).
/// A wasm host has no threads and starts none.
template <typename Pool>
inline void spawn_pool_workers(Pool *pool, usize count, usize stack_bytes) {
#if !defined(_WIN32) && !defined(__wasm__)
    for (usize i = 0; i < count; ++i) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        // A refused size would leave the platform default (512 KiB on macOS),
        // which the compiler's recursion does not fit in.
        int rc = pthread_attr_setstacksize(&attr, stack_bytes);
        pthread_t tid;
        auto *arg = new ::std::pair<Pool *, usize>(pool, i);
        if (rc == 0) {
            rc = pthread_create(&tid, &attr, [](void *raw) -> void * {
                auto *p = static_cast<::std::pair<Pool *, usize> *>(raw);
                p->first->worker_loop(p->second);
                delete p;
                return nullptr;
            }, arg);
        }
        pthread_attr_destroy(&attr);
        if (rc != 0) {
            delete arg;
            native::worker_start_failed(i, count, ::std::strerror(rc));
        }
        pthread_detach(tid);
    }
#elif defined(_WIN32)
    for (usize i = 0; i < count; ++i) {
        auto *arg = new ::std::pair<Pool *, usize>(pool, i);
        bool started = kairo::win32::spawn_thread([](void *raw) {
            auto *p = static_cast<::std::pair<Pool *, usize> *>(raw);
            p->first->worker_loop(p->second);
            delete p;
        }, arg, stack_bytes);
        if (!started) {
            delete arg;
            native::worker_start_failed(i, count, "CreateThread failed");
        }
    }
#else
    (void)pool;
    (void)count;
    (void)stack_bytes;
#endif
}

namespace native {

/// What execute_on_big_stack hands its thread: the call to make and where an
/// exception thrown by it is kept for the caller.
template <typename Ci, typename R>
struct BigStackJob {
    Ci *ci;
    R *out;
    ::std::exception_ptr err;

    static void run(void *raw) noexcept {
        auto *j = static_cast<BigStackJob *>(raw);
        try {
            *j->out = j->ci->execute();
        } catch (...) {
            j->err = ::std::current_exception();
        }
    }
};

}  // namespace native

/// Runs `*out = ci->execute()` on a new thread with a stack of \p stack_bytes and
/// waits for it, so the driver's own work (the entry file's parse and Sema,
/// codegen) has the pool workers' stack rather than the main thread's,
/// which the OS or the linker sizes (8 MB on Linux, 1 MB on Windows, 512 KB
/// to 8 MB elsewhere). A left-deep 30000-term `1 + 1 + ...` chain recurses
/// past 8 MB in the entry file's Sema. An exception thrown on that thread is
/// rethrown here. Where the thread cannot be made (a wasm host, or thread
/// creation failing) the call runs on the calling thread. Templated on the
/// instance so this header needs no declaration of CompilerInstance, a
/// Kairo class.
template <typename Ci, typename R>
inline void execute_on_big_stack(Ci *ci, R *out, usize stack_bytes) {
#if !defined(__wasm__)
    using Job = native::BigStackJob<Ci, R>;
    Job  job{ci, out, nullptr};
    bool ran = false;
#if defined(_WIN32)
    ran = kairo::win32::run_on_thread(&Job::run, &job, stack_bytes);
#else
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_t tid;
    int rc = pthread_attr_setstacksize(&attr, stack_bytes);
    if (rc == 0) {
        rc = pthread_create(&tid, &attr, [](void *raw) -> void * {
            Job::run(raw);
            return nullptr;
        }, &job);
    }
    pthread_attr_destroy(&attr);
    if (rc == 0) {
        pthread_join(tid, nullptr);
        ran = true;
    }
#endif
    if (ran) {
        if (job.err) {
            ::std::rethrow_exception(job.err);
        }
        return;
    }
#else
    (void)stack_bytes;
#endif
    *out = ci->execute();
}

/// The calling thread's cached queue index for ThreadPool::enqueue, or
/// usize(-1) before its first enqueue. Shared by every pool on the thread.
inline usize *thread_pool_local_qid() {
    thread_local usize local_qid = static_cast<usize>(-1);
    return &local_qid;
}

/// Where DiagEngine::emit puts what the calling thread reports, or null for
/// the engine itself: a DiagEngineVBase (a BufferedDiagSink, opaque here)
/// that a task of a parallel phase holds while it runs (DiagCapture), so
/// the phase can hand its files' diagnostics to the engine in a fixed order
/// instead of the order the tasks happen to finish in.
inline void **diag_capture() {
    thread_local void *sink = nullptr;
    return &sink;
}

/// The dependency log of the translation unit whose Sema the calling thread
/// is running, or null: no log (the flags that ask for one are off), or no
/// Sema on this thread. AST/Context/DepLog.k owns the pointee; a symbol
/// table has no way to know who is asking, so the asker is per-thread state
/// that Sema's entry points set (DepLogScope) and the lookup chokepoints
/// read. Off costs each lookup this one load and a null test.
inline void **sema_dep_log() {
    thread_local void *log = nullptr;
    return &log;
}

/// The calling thread's place in the serial Sema order, for
/// InstantiationRegistry: the rank of the import group whose Sema this
/// thread is running (its place in the build's group order, narrowed to the
/// schedule step, FrontendAction's sema_sub), or u64(-1) on a thread
/// running none.
inline u64 *sema_mint_rank() {
    thread_local u64 rank = ~static_cast<u64>(0);
    return &rank;
}

/// That group's request counter (null with no group): one counter per
/// group, not per thread, because a group's typed checks run on a pool
/// worker and the rest of its Sema on the driver thread, and its mints
/// must number in the order a one-thread run would have made them.
inline u64 **sema_mint_counter() {
    thread_local u64 *counter = nullptr;
    return &counter;
}

/// While ForeignInstantiate fills a shell on this thread: the list (a
/// std::vector<InstanceEntry*>, opaque here) every registry request of the
/// fill is appended to, so a TU earlier in import order that finds the
/// shell already filled can re-request them and take their homes back.
/// Null otherwise.
inline void **sema_fill_record() {
    thread_local void *record = nullptr;
    return &record;
}

/// One slot of PartitionQueue's ring: a ticket counter and the stored value,
/// aligned to \p Align (the target's cache line) so neighbouring slots never
/// share a line under concurrent producers and consumers.
///
/// Moves relax through the atomic: ordering is established by the queue's
/// push()/pop(), never by relocating the buffer. Copies are deleted.
template <typename T, usize Align>
struct alignas(Align) SeqCell {
    ::std::atomic<u64>        seq{0};
    T                         val;

    SeqCell() = default;

    SeqCell(SeqCell &&other) noexcept {
        auto seq_val = other.seq.load(::std::memory_order::relaxed);
        seq.store(seq_val, ::std::memory_order::relaxed);

        val = ::std::move(other.val);
    }

    SeqCell &operator=(SeqCell &&other) noexcept {
        if (this != &other) {
            auto seq_val = other.seq.load(::std::memory_order::relaxed);
            seq.store(seq_val, ::std::memory_order::relaxed);

            val = ::std::move(other.val);
        }

        return *this;
    }

    SeqCell(const SeqCell &)            = delete;
    SeqCell &operator=(const SeqCell &) = delete;
};

}  // namespace kairo

#endif  // __KAIRO_NATIVE_KTHREAD_HH__
