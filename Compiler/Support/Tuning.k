/// --- The Kairo Project ----------------------------- Support/Tuning.k --- ///
///
///   The compiler's internal caps, one place. Each says what it trades off.
///   None is a language limit a user sets (those are --cmax-* flags, with
///   their defaults in Command/FlagRegistry.k) and none is a format value.
///
///   `eval`, not `const`: an imported `const` reaches the importing C++ unit
///   as an extern load, an `eval` as the literal itself.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// How many `derives` edges a walk up a class's bases follows before it
/// answers "not derived" (overload ranking, access paths, base-initializer
/// checks). Most of the walks also carry a seen-list, so this mostly bounds
/// a chain that is really that deep. Higher: deeper hierarchies are judged; lower:
/// a pathological chain costs less before it is cut off.
pub
eval DERIVES_WALK_DEPTH_MAX: u32 = 64


/// Nanoseconds per second and per day, for the ages below.
pub
eval NS_PER_SEC: u64 = 1000000000 as u64
pub
eval NS_PER_DAY: u64 = (86400 as u64) * NS_PER_SEC

/// The object and library caches evict an entry stored longer ago than
/// this (mtime is store time, not last use). Higher: more hits after a long
/// break, more disk held.
pub
eval CACHE_ENTRY_MAX_AGE_NS: u64 = 30 * NS_PER_DAY

/// The object cache (Driver/ObjectCache.k) keeps at most this many bytes
/// of objects; past it, the oldest-stored go, down to three quarters of
/// it. About five generations of the compiler's own debug objects. Higher:
/// more hits after switching between trees; lower: less disk per output
/// tree.
pub
eval CACHE_OBJECTS_MAX_BYTES: u64 = (2048 as u64) * 1024 * 1024

/// The runtime cache and the Kairo library cache (Driver/CompilerCache.k)
/// each keep at most this many bytes, evicted as the object cache is
/// (a library cache gains one entry per compiler build, target and option
/// set, so without a cap a cache root grows without bound). Higher:
/// fewer rebuilds after switching between compilers or options; lower: less
/// disk per cache root.
pub
eval CACHE_LIBRARY_MAX_BYTES: u64 = (2048 as u64) * 1024 * 1024

/// An object stored this recently is never evicted for size: it is the
/// generation the run (or a parallel one) just wrote.
pub
eval CACHE_RECENT_STORE_NS: u64 = 3600 * NS_PER_SEC

/// A partial copy (`.tmp-`, `.stale-`) older than this is a crashed store's
/// and is removed. Lower reclaims sooner, but must stay well above the
/// longest store a live run can be in the middle of.
pub
eval CACHE_PARTIAL_MAX_AGE_NS: u64 = NS_PER_DAY

/// A file whose mtime is within this of the run's start is hashed rather
/// than trusted by mtime: a coarse filesystem clock can give an edit made
/// during the run the same stamp. Higher: more files hashed each run;
/// lower: a same-tick edit can be missed on such a filesystem.
pub
eval MTIME_SLACK_NS: u64 = 2 * NS_PER_SEC

/// The stack each thread-pool worker starts with (Threading/ThreadPool.k,
/// Native/KThread.hh). Sema and the printers recurse once per level of a
/// nested expression, so this bounds how deep a chain a worker can check.
/// The main thread keeps the stack the OS gave it, which is
/// usually smaller and also runs Sema. Higher: deeper input survives; lower:
/// less address space reserved per worker.
pub
eval WORKER_STACK_BYTES: usize = (32 * 1024 * 1024) as usize
