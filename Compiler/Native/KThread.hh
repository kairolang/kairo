/// --- The Kairo Project ---------------------------- Native/KThread.hh --- ///
///
///   Thread-pool plumbing Kairo cannot spell: native thread creation with an
///   explicit stack size, a thread_local, and a cache-line-aligned queue cell.
///
///   WHY C++: pthread_create / CreateThread take a C callback, `thread_local`
///   and `alignas` have no Kairo spelling, and the cell needs a hand-written
///   move that relaxes through an atomic. These used to be inline C++
///   blocks inside ThreadPool and PartitionQueue; Stage 1 does not emit
///   inline foreign blocks, so the C++ lives here.
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

#include "KPrelude.hh"
#include <atomic>
#include <utility>

#if defined(_WIN32)
#include "Win32.hh"   // spawn_thread; never <windows.h> here
#else
#include <pthread.h>
#endif

namespace kairo {

/// Starts \p count detached native threads, thread i running
/// `pool->worker_loop(i)`, each with a 32 MiB stack. Templated on the pool
/// so this header needs no declaration of ThreadPool, which is a Kairo
/// class; the pair handed to the thread is freed by the thread.
///
/// Platforms other than POSIX (macOS/Linux) and Windows start no threads,
/// exactly as the inline block this replaces did.
template <typename Pool>
inline void spawn_pool_workers(Pool *pool, usize count) {
#if !defined(_WIN32) && !defined(__wasm__)
    // Every POSIX system, BSDs included: guarded by __APPLE__ || __linux__ before,
    // a FreeBSD / NetBSD compiler started no pool workers at all.
    for (usize i = 0; i < count; ++i) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 32UL * 1024 * 1024);
        pthread_t tid;
        auto *arg = new ::std::pair<Pool *, usize>(pool, i);
        pthread_create(&tid, &attr, [](void *raw) -> void * {
            auto *p = static_cast<::std::pair<Pool *, usize> *>(raw);
            p->first->worker_loop(p->second);
            delete p;
            return nullptr;
        }, arg);
        pthread_attr_destroy(&attr);
        pthread_detach(tid);
    }
#elif defined(_WIN32)
    for (usize i = 0; i < count; ++i) {
        auto *arg = new ::std::pair<Pool *, usize>(pool, i);
        kairo::win32::spawn_thread([](void *raw) {
            auto *p = static_cast<::std::pair<Pool *, usize> *>(raw);
            p->first->worker_loop(p->second);
            delete p;
        }, arg, 32UL * 1024 * 1024);
    }
#else
    (void)pool;
    (void)count;
#endif
}

/// The calling thread's cached queue index for ThreadPool::enqueue, or
/// usize(-1) before its first enqueue. Shared by every pool on the thread,
/// as the function-local thread_local it replaces was.
inline usize *thread_pool_local_qid() {
    thread_local usize local_qid = static_cast<usize>(-1);
    return &local_qid;
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
