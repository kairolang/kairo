/// --- The Kairo Project ------------------------------ Native/Thread.k --- ///
///
///   The per-thread slots the compiler's threads keep: the pool's queue
///   index, the diagnostic capture, and the Sema state of the group a
///   thread is running. Thread creation and the queue cell are
///   Native/Thread.hh.
///
///   Each accessor is an inline function returning the address of a
///   function-local `thread` variable (a C++ inline function's
///   `static thread_local`): one instance per thread program-wide, however
///   many modules inline it.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The calling thread's cached queue index for ThreadPool::enqueue, or
/// usize(-1) before its first enqueue. Shared by every pool on the thread.
pub inline fn thread_pool_local_qid() -> unsafe *usize {
    thread local_qid: usize = usize::MAX
    return unsafe &local_qid
}

/// Where DiagEngine::emit puts what the calling thread reports, or null for
/// the engine itself: a DiagEngineVBase (a BufferedDiagSink, opaque here)
/// that a task of a parallel phase holds while it runs (DiagCapture), so
/// the phase can hand its files' diagnostics to the engine in a fixed order
/// instead of the order the tasks happen to finish in.
pub inline fn diag_capture() -> unsafe *unsafe *void {
    thread sink: unsafe *void = &null
    return unsafe &sink
}

/// The dependency log of the translation unit whose Sema the calling thread
/// is running, or null: no log (the flags that ask for one are off), or no
/// Sema on this thread. AST/Context/DepLog.k owns the pointee; a symbol
/// table has no way to know who is asking, so the asker is per-thread state
/// that Sema's entry points set (DepLogScope) and the lookup chokepoints
/// read. Off costs each lookup this one load and a null test.
pub inline fn sema_dep_log() -> unsafe *unsafe *void {
    thread log: unsafe *void = &null
    return unsafe &log
}

/// The calling thread's place in the serial Sema order, for
/// InstantiationRegistry: the rank of the import group whose Sema this
/// thread is running (its place in the build's group order, narrowed to the
/// schedule step, FrontendAction's sema_sub), or u64(-1) on a thread
/// running none.
pub inline fn sema_mint_rank() -> unsafe *u64 {
    thread rank: u64 = u64::MAX
    return unsafe &rank
}

/// That group's request counter (null with no group): one counter per
/// group, not per thread, because a group's typed checks run on a pool
/// worker and the rest of its Sema on the driver thread, and its mints
/// must number in the order a one-thread run would have made them.
pub inline fn sema_mint_counter() -> unsafe *unsafe *u64 {
    thread counter: unsafe *u64 = &null
    return unsafe &counter
}

/// While ForeignInstantiate fills a shell on this thread: the list (a
/// std::vector<InstanceEntry*>, opaque here) every registry request of the
/// fill is appended to, so a TU earlier in import order that finds the
/// shell already filled can re-request them and take their homes back.
/// Null otherwise.
pub inline fn sema_fill_record() -> unsafe *unsafe *void {
    thread record: unsafe *void = &null
    return unsafe &record
}
