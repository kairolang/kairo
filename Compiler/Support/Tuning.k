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
