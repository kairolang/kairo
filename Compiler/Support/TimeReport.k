/// --- The Kairo Project ------------------------- Support/TimeReport.k --- ///
///
///   Kairo surface over the pass-timing engine in Native/KTimeReport.hh.
///
///   WHY TWO FILES: the registry needs thread_local state, atomics and a
///   shared_mutex, and it has to be callable from inside the `inline "c++"`
///   pool lambdas in FrontendAction::_parse   which is where most of the
///   interesting time goes. That part is C++. This is the thin RAII surface
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KTimeReport.hh";

/// \brief arms the registry. Nothing is measured before this runs, and the
///        wall clock every percentage divides by starts HERE.
///
/// \param on     master switch (--time-passes).
/// \param trace  additionally record every region entry as a Chrome Trace
///               event for time_write_trace (--time-trace=FILE). Costs one
///               vector push per region, so it is off unless asked for.
inline fn time_enable(on: bool, trace: bool = false) {
    kairo::ktime_enable(on, trace);
}

inline fn time_enabled() -> bool { return kairo::ktime_enabled(); }

/// \brief stops the wall clock the report's % column is taken against.
///        Idempotent; time_print() calls it.
inline fn time_finish() { kairo::ktime_finish(); }

/// \brief writes the aggregate report to stderr.
///
/// \details stderr, not stdout, for the same reason clang does it: -E and
///          --emit write real output to stdout and a timing table in the
///          middle of it would corrupt the artifact.
inline fn time_print() { kairo::ktime_print(); }

/// \brief writes a Chrome Trace Event JSON file (chrome://tracing, Perfetto,
///        speedscope).
///
/// \details The aggregate report says WHICH region is slow. This says when it
///          ran, on which worker, and what ran beside it   the only way to see
///          a serialized import wave, a starved pool, or which single file
///          owns the critical path. No-op unless time_enable was called with
///          trace = true.
fn time_write_trace(path: string) -> bool {
    if path.empty() { return false; }
    var p = std::string_to_nstring(path);
    return kairo::ktime_write_trace(p.raw());
}

/// \brief the region active on this thread, for handing to a pool task.
///        Null when timing is off, which TimeWorker tolerates.
inline fn time_current() -> *kairo::KTimeRecord {
    return kairo::ktime_current();
}

/// \brief interns \p name as a child of the active region and returns the
///        stable handle.
///
/// \details For a call site hot enough that the per-entry map lookup shows up:
///          resolve once, then construct from the handle. Valid for the life
///          of the process.
fn time_region(name: string) -> *kairo::KTimeRecord {
    var n = std::string_to_nstring(name);
    return kairo::ktime_region(n.raw());
}

/// \brief interns \p name as a SIBLING of the active region.
///
/// \details For a handle that has to be resolved from inside a setup scope but
///          does not belong under it. The Lexer resolves its record while the
///          stream is being opened, but lex time is not part of opening the
///          stream   it belongs beside it, under the walk.
fn time_region_beside(name: string) -> *kairo::KTimeRecord {
    var n = std::string_to_nstring(name);
    return kairo::ktime_region_beside(n.raw());
}

/// \brief marks \p rec a busy-wait: real elapsed time, but not work anyone can
///        make faster   only work they can stop doing.
///
/// \details Excluded from the hot list. A spin-waiting flusher otherwise sits
///          permanently at the top of the list of things to go optimize, which
///          is both wrong and load-bearing enough to hide the real entries.
inline fn time_mark_idle(rec: *kairo::KTimeRecord) { kairo::ktime_mark_idle(rec); }

/// \brief tells the report how many ThreadPool workers exist.
///
/// \details The registry cannot infer this. What it can count is how many
///          threads RECORDED a region, which is a different number and always
///          will be   the driver records, and so does the parse diagnostic
///          flusher, and neither is a pool worker. Printing that next to a
///          --threads=N flag reads like an off-by-one because it is not the
///          same quantity. The report prints both, labelled.
inline fn time_set_pool_size(n: i32) { kairo::ktime_set_pool_size(n); }

/// \class TimeRegion
/// \brief RAII timed region. Records on scope exit.
///
/// \note NOT movable or copyable   two live copies would double-count. Bind it
///       to a `var` and let it die with the scope.
class TimeRegion {
    priv var _f: kairo::KTimeFrame;

    /// Resolves \p name against the region active on this thread. Costs one
    /// small-map lookup plus a narrow-string conversion; negligible next to a
    /// pipeline stage, too much for a per-token region   use TimeSampled
    /// there.
    inline fn TimeRegion(self, name: string) {
        if !kairo::ktime_enabled() { return; }
        var n = std::string_to_nstring(name);
        self._f = kairo::ktime_enter(kairo::ktime_region(n.raw()));
    }

    /// Pre-resolved handle from time_region(). No lookup, no allocation.
    inline fn TimeRegion(self, rec: *kairo::KTimeRecord) {
        if !kairo::ktime_enabled() { return; }
        self._f = kairo::ktime_enter(rec);
    }

    delete fn TimeRegion(self, other: ref!(TimeRegion));
    delete fn op = (self, other: ref!(TimeRegion)) -> ref!(TimeRegion);

    inline fn op delete (self) { kairo::ktime_leave(self._f); }

    /// The handle for this region, to hand to pool tasks that will do a slice
    /// of it. Same as time_current() while this scope is the innermost one.
    inline fn record(self) -> *kairo::KTimeRecord {
        return kairo::ktime_frame_record(self._f);
    }

    /// \brief adds to this region's throughput counter.
    ///
    /// \details Reported as \p label per second, so the table answers "is the
    ///          parser slow, or is that file just enormous". Pass bytes with
    ///          "B", tokens with "tok", lines with "line". The label is taken
    ///          from the first call and ignored afterwards.
    inline fn units(self, n: u64, label: *kairo::std::Legacy::char) {
        kairo::ktime_units(kairo::ktime_frame_record(self._f), n, label);
    }
}

/// \class TimeSampled
/// \brief times one entry in \p stride and scales by \p stride.
///
/// \details For a region on a per-token path. Two clock reads per entry is
///          ~50ns through the vDSO on aarch64; against a ~20ns tokenizer step
///          that measures the measurement and reports a number two thirds of
///          which is the instrument. Sampling brings it to ~1ns amortized.
///
///          \p counter must be owned by the caller and NOT shared across
///          threads   a shared counter costs a contended cache line per token,
///          which is the exact cost this exists to avoid. Put it on the object
///          being measured (see Lexer::_lex_sample).
///
/// \warning The result is an ESTIMATE and the report marks the row `~`. Over
///          millions of entries the sampling error is far below anything worth
///          acting on, but do not quote it as measured.
class TimeSampled {
    priv var _f: kairo::KTimeFrame;

    inline fn TimeSampled(self, rec: *kairo::KTimeRecord, stride: u32, counter: *u32) {
        self._f = kairo::ktime_enter_sampled(rec, stride, counter);
    }

    delete fn TimeSampled(self, other: ref!(TimeSampled));
    delete fn op = (self, other: ref!(TimeSampled)) -> ref!(TimeSampled);

    inline fn op delete (self) { kairo::ktime_leave(self._f); }
}

/// \class TimeWorker
/// \brief a pool task doing a slice of \p rec. Open this FIRST in the task.
///
/// \details Roots this thread's region stack under \p rec's parent so nested
///          regions land in the right place, then enters \p rec itself with
///          the entry billed to WORK rather than wall.
///
///          Worker time is deliberately not billed to the dispatcher's child
///          time. The dispatcher is measuring latency on another thread while
///          the workers accumulate work; subtracting one from the other would
///          drive the dispatcher's self time negative. The report divides them
///          into `par` instead, which is the parallel speedup the fan-out
///          actually achieved.
class TimeWorker {
    priv var _w: kairo::KTimeWorker;

    inline fn TimeWorker(self, rec: *kairo::KTimeRecord) {
        self._w = kairo::ktime_worker_enter(rec);
    }

    delete fn TimeWorker(self, other: ref!(TimeWorker));
    delete fn op = (self, other: ref!(TimeWorker)) -> ref!(TimeWorker);

    inline fn op delete (self) { kairo::ktime_worker_leave(self._w); }

    inline fn units(self, n: u64, label: *kairo::std::Legacy::char) {
        kairo::ktime_units(kairo::ktime_worker_record(self._w), n, label);
    }
}

/// \class TimeThreadRoot
/// \brief roots this thread's region stack at \p parent without billing the
///        task's own time anywhere.
///
/// \details Prefer TimeWorker. This is for a task whose own duration is not
///          meaningful   a spin-waiting flusher, a watchdog   but which opens
///          regions that must still land in the right place in the tree.
class TimeThreadRoot {
    priv var _b: kairo::KTimeRoot;

    inline fn TimeThreadRoot(self, parent: *kairo::KTimeRecord) {
        self._b = kairo::ktime_root_enter(parent);
    }

    delete fn TimeThreadRoot(self, other: ref!(TimeThreadRoot));
    delete fn op = (self, other: ref!(TimeThreadRoot)) -> ref!(TimeThreadRoot);

    inline fn op delete (self) { kairo::ktime_root_leave(self._b); }
}
