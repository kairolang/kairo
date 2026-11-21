/// --- The Kairo Project ------------------------- Support/TimeReport.k --- ///
///
///   Kairo surface over the pass-timing engine in Native/TimeReport.k.
///
///   WHY TWO FILES: the registry needs thread_local state, atomics and a
///   shared_mutex, and it has to be callable from C++ (the Native/ headers)
///   as well as from Kairo. That part is C++. This is the thin RAII surface
///   for call sites that are plain Kairo.
///
///   WHY NOT Support/Timer.k: Timer prints one line per scope and knows
///   nothing about nesting, aggregation, or other threads. It is a one-off
///   measurement tool. This aggregates a whole run into a tree.
///
///   USAGE
///   -----
///       {
///           var _t = TimeRegion("Parse");
///           ...
///       }   // scope exit records it
///
///   Nesting is implicit: a TimeRegion opened while another is live on the
///   same thread becomes its child. Name the region for what it DOES, not for
///   where it sits.
///
///   FANNED-OUT WORK IS ONE REGION, NOT TWO. The driver enters it to dispatch
///   and wait; every worker enters the SAME record to do a slice. Capture the
///   handle on the dispatching thread, open a TimeWorker with it in the task:
///
///       {
///           var _t   = TimeRegion("Full");
///           var rec  = time_current();
///           pool->enqueue(fn() {
///               var _w = TimeWorker(rec);
///               ...
///           });
///           pool->wait_group(g);
///       }
///
///   The dispatcher's time lands in `wall` (latency), the workers' in `work`
///   (summed), and the report divides them into `par`. One row.
///
///   COST WHEN OFF: one relaxed atomic load per region. No clock read, no
///   allocation. Leave the instrumentation in.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


import Native::TimeReport::{
    KTimeFrame,
    KTimeRecord,
    KTimeRoot,
    KTimeWorker,
    ktime_bill_since,
    ktime_clock,
    ktime_current,
    ktime_enable,
    ktime_enabled,
    ktime_enter,
    ktime_enter_sampled,
    ktime_finish,
    ktime_frame_record,
    ktime_leave,
    ktime_mark_idle,
    ktime_print,
    ktime_region,
    ktime_region_beside,
    ktime_root_enter,
    ktime_root_leave,
    ktime_set_pool_size,
    ktime_units,
    ktime_worker_enter,
    ktime_worker_leave,
    ktime_worker_record,
    ktime_write_trace,
}
import std::c_char

/// arms the registry. Nothing is measured before this runs, and the
/// wall clock every percentage divides by starts HERE.
///
/// ### Parameters
/// - `on`: master switch (--time-passes).
/// - `trace`: additionally record every region entry as a Chrome Trace
///   event for time_write_trace (--time-trace=FILE). Costs one
///   vector push per region, so it is off unless asked for.
pub inline fn time_enable(on: bool, trace: bool = false) {
    ktime_enable(on, trace)
}

pub inline fn time_enabled() -> bool {
    return ktime_enabled()
}

/// stops the wall clock the report's % column is taken against.
/// Idempotent; time_print() calls it.
pub inline fn time_finish() {
    ktime_finish()
}

/// writes the aggregate report to stderr.
///
/// stderr, not stdout, for the same reason clang does it: -E and
/// --emit write real output to stdout and a timing table in the
/// middle of it would corrupt the artifact.
pub inline fn time_print() {
    ktime_print()
}

/// writes a Chrome Trace Event JSON file (chrome://tracing, Perfetto,
/// speedscope).
///
/// The aggregate report says WHICH region is slow. This says when it
/// ran, on which worker, and what ran beside it   the only way to see
/// a serialized import wave, a starved pool, or which single file
/// owns the critical path. No-op unless time_enable was called with
/// trace = true.
pub fn time_write_trace(const path: string) -> bool {
    if path.is_empty() {
        return false
    }

    var p = path.copy()
    return ktime_write_trace(p.c_str())
}

/// the region active on this thread, for handing to a pool task.
/// Null when timing is off, which TimeWorker tolerates.
pub inline fn time_current() -> unsafe *KTimeRecord {
    return ktime_current()
}

/// interns `name` as a child of the active region and returns the
/// stable handle.
///
/// For a call site hot enough that the per-entry map lookup shows up:
/// resolve once, then construct from the handle. Valid for the life
/// of the process.
pub fn time_region(const name: string) -> unsafe *KTimeRecord {
    var n = name.copy()
    return ktime_region(n.c_str())
}

/// interns `name` as a SIBLING of the active region.
///
/// For a handle that has to be resolved from inside a setup scope but
/// does not belong under it. The Lexer resolves its record while the
/// stream is being opened, but lex time is not part of opening the
/// stream   it belongs beside it, under the walk.
pub fn time_region_beside(const name: string) -> unsafe *KTimeRecord {
    var n = name.copy()
    return ktime_region_beside(n.c_str())
}

/// marks `rec` a busy-wait: real elapsed time, but not work anyone can
/// make faster   only work they can stop doing.
///
/// Excluded from the hot list. A spin-waiting flusher otherwise sits
/// permanently at the top of the list of things to go optimize, which
/// is both wrong and load-bearing enough to hide the real entries.
pub inline fn time_mark_idle(rec: unsafe *KTimeRecord) {
    ktime_mark_idle(rec)
}

/// the region clock, or 0 while timing is off.
///
/// For a span a TimeRegion cannot scope: one whose variables have to
/// outlive the block that would close it (an object created in the
/// span and used after). Pair with time_bill_since.
pub inline fn time_clock() -> u64 {
    return ktime_clock()
}

/// bills [`t0`, now) to the child `name` of the open region, as a
/// TimeRegion("name") over that span would have. Nothing when `t0`
/// is 0 (time_clock() with timing off).
pub fn time_bill_since(const name: string, t0: u64) {
    if t0 == 0 {
        return
    }

    var n = name.copy()
    ktime_bill_since(n.c_str(), t0)
}

/// tells the report how many ThreadPool workers exist.
///
/// The registry cannot infer this. What it can count is how many
/// threads RECORDED a region, which is a different number and always
/// will be   the driver records, and so does the parse diagnostic
/// flusher, and neither is a pool worker. Printing that next to a
/// --threads=N flag reads like an off-by-one because it is not the
/// same quantity. The report prints both, labelled.
pub inline fn time_set_pool_size(n: i32) {
    ktime_set_pool_size(n)
}

/// RAII timed region. Records on scope exit.
///
/// **Note:** NOT movable or copyable   two live copies would double-count. Bind it
/// to a `var` and let it die with the scope.
pub class TimeRegion {
    priv var _f: KTimeFrame

    /// Resolves `name` against the region active on this thread. Costs one
    /// small-map lookup plus a narrow-string conversion; negligible next to a
    /// pipeline stage, too much for a per-token region   use TimeSampled
    /// there.
    pub inline fn TimeRegion(self, const name: string) {
        if !ktime_enabled() {
            return
        }

        var n = name.copy()
        self._f = ktime_enter(ktime_region(n.c_str()))
    }

    /// Pre-resolved handle from time_region(). No lookup, no allocation.
    pub inline fn TimeRegion(self, rec: unsafe *KTimeRecord) {
        if !ktime_enabled() {
            return
        }

        self._f = ktime_enter(rec)
    }

    @copy fn TimeRegion(self, const other: Self) = delete

    inline fn op finally (self) {
        ktime_leave(self._f)
    }

    /// The handle for this region, to hand to pool tasks that will do a slice
    /// of it. Same as time_current() while this scope is the innermost one.
    pub inline fn record(self) -> unsafe *KTimeRecord {
        return ktime_frame_record(self._f)
    }

    /// adds to this region's throughput counter.
    ///
    /// Reported as `label` per second, so the table answers "is the
    /// parser slow, or is that file just enormous". Pass bytes with
    /// "B", tokens with "tok", lines with "line". The label is taken
    /// from the first call and ignored afterwards.
    inline fn units(self, n: u64, label: unsafe *const c_char) {
        ktime_units(ktime_frame_record(self._f), n, label)
    }
}

/// times one entry in `stride` and scales by `stride`.
///
/// For a region on a per-token path. Two clock reads per entry is
/// ~50ns through the vDSO on aarch64; against a ~20ns tokenizer step
/// that measures the measurement and reports a number two thirds of
/// which is the instrument. Sampling brings it to ~1ns amortized.
///
///          `counter` must be owned by the caller and NOT shared across
///          threads   a shared counter costs a contended cache line per token,
///          which is the exact cost this exists to avoid. Put it on the object
///          being measured (see Lexer::_lex_sample).
///
/// **Warning:** The result is an ESTIMATE and the report marks the row `~`. Over
/// millions of entries the sampling error is far below anything worth
/// acting on, but do not quote it as measured.
pub class TimeSampled {
    priv var _f: KTimeFrame

    pub inline fn TimeSampled(self, rec: unsafe *KTimeRecord, stride: u32, counter: unsafe *u32) {
        self._f = ktime_enter_sampled(rec, stride, counter)
    }

    @copy fn TimeSampled(self, const other: Self) = delete

    inline fn op finally (self) {
        ktime_leave(self._f)
    }
}

/// a pool task doing a slice of `rec`. Open this FIRST in the task.
///
/// Roots this thread's region stack under `rec`'s parent so nested
/// regions land in the right place, then enters `rec` itself with
/// the entry billed to WORK rather than wall.
///
///          Worker time is deliberately not billed to the dispatcher's child
///          time. The dispatcher is measuring latency on another thread while
///          the workers accumulate work; subtracting one from the other would
///          drive the dispatcher's self time negative. The report divides them
///          into `par` instead, which is the parallel speedup the fan-out
///          actually achieved.
pub class TimeWorker {
    priv var _w: KTimeWorker

    pub inline fn TimeWorker(self, rec: unsafe *KTimeRecord) {
        self._w = ktime_worker_enter(rec)
    }

    @copy fn TimeWorker(self, const other: Self) = delete

    inline fn op finally (self) {
        ktime_worker_leave(self._w)
    }

    pub inline fn units(self, n: u64, label: unsafe *const c_char) {
        ktime_units(ktime_worker_record(self._w), n, label)
    }
}

/// roots this thread's region stack at `parent` without billing the
/// task's own time anywhere.
///
/// Prefer TimeWorker. This is for a task whose own duration is not
/// meaningful   a spin-waiting flusher, a watchdog   but which opens
/// regions that must still land in the right place in the tree.
pub class TimeThreadRoot {
    priv var _b: KTimeRoot

    inline fn TimeThreadRoot(self, parent: unsafe *KTimeRecord) {
        self._b = ktime_root_enter(parent)
    }

    @copy fn TimeThreadRoot(self, const other: Self) = delete

    inline fn op finally (self) {
        ktime_root_leave(self._b)
    }
}
