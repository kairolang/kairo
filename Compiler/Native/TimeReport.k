/// --- The Kairo Project ------------------------- Native/TimeReport.k --- ///
///
///   Hierarchical, thread-aware pass timing.  The engine behind --time-passes
///   and --time-trace.
///
///   WHY NOT Support/Timer.k: that one prints a line per scope and knows
///   nothing about nesting, aggregation, or other threads.  Useful for a
///   one-off measurement, useless for finding a bottleneck in a pipeline that
///   fans 148 files across a work-stealing pool.
///
///   Support/TimeReport.k is the wrapper for call sites that are plain
///   Kairo; this module is the registry under it.
///
///   MODEL
///   -----
///   A Record is one named region, identified by its FULL PATH   the dotted
///   chain of regions active on the entering thread ("Preprocess.Walk.Lex").
///   The path is resolved by walking the thread's current record, so nesting
///   is implicit at the call site: name the region for what it does, not for
///   where it sits.
///
///   WALL AND WORK ARE THE SAME RECORD.  A fanned-out stage is one region, not
///   two.  The driver enters it to dispatch and wait; every worker enters the
///   SAME record to do a slice of the job.  The two are billed apart:
///
///     wall_ns   time on the dispatching thread   LATENCY
///     work_ns   time summed over workers         WORK
///     par       work / wall                      the speedup the fan-out got
///
///   That is why there is no `Parse` / `parse-task` pair of rows: one row,
///   two columns, and the ratio computed.
///
///   Other per-record fields:
///     child_ns  inclusive time of children entered on the same thread
///     self_ns   work (or wall, if the region never ran on a worker) - child
///     max_ns    slowest single entry   the one pathological file
///     units     optional throughput counter (bytes, tokens, lines)
///
///   SAMPLING.  A region on a per-token path cannot afford two clock reads per
///   entry: clock_gettime through the vDSO is ~25ns on aarch64, which against
///   a ~20ns tokenizer step measures the measurement.  A sampled entry times one
///   entry in `stride` and scales, for ~1ns amortized.  Sampled rows are
///   marked `~` and their numbers are estimates.
///
///   IDLE.  A region marked idle is a busy-wait, not work.  It is excluded
///   from the hot list so a spinning flusher does not sit at the top of the
///   list of things to go optimize.
///
///   COST WHEN OFF.  One relaxed atomic load per scope.  Nothing is allocated,
///   no clock is read.  Leave the instrumentation in.
///
///   The registry, the flags and the per-thread state are function-local
///   statics of inline functions: one instance program-wide however many
///   modules inline them.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Shims.hh" // std_err
ffi "c++" import "Native/Types.hh" // Atomic, SharedMutex, create
ffi "c++" import "algorithm"
ffi "c++" import "chrono"
ffi "c++" import "cstdio"
ffi "c++" import "cstring"
ffi "c++" import "shared_mutex"
ffi "c++" import "string"
ffi "c++" import "unordered_map"
ffi "c++" import "vector"

import std::c_char

pub class TimeReport {
    pub type Clock = cxx::std::chrono::steady_clock
    pub type Stamp = cxx::std::chrono::steady_clock::time_point

    /// ## Record

    /// One named region. Heap-owned by the registry and never freed before
    /// process exit: every Record* handed out stays valid, which is what lets
    /// a hot call site hoist its lookup out of the loop.
    pub class Record {
        pub var name:   cxx::std::string                   ///< leaf name
        pub var path:   cxx::std::string                   ///< full dotted path (the identity)
        pub var parent: unsafe *TimeReport::Record = &null
        pub var depth:  u32                        = 0

        /// Dispatching-thread time. Latency.
        pub var wall_ns:    kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
        pub var wall_calls: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

        /// Worker time, summed across every thread that entered under a
        /// TimeWorker. Work.
        pub var work_ns:    kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
        pub var work_calls: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

        pub var child_ns: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
        pub var units:    kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

        /// Slowest single entry, tracked PER KIND.
        ///
        /// A shared max would be wrong. A fanned-out region's wall entry is
        /// the whole dispatch-and-wait, which is by construction longer than
        /// any one worker slice, so a shared max always reports the
        /// dispatcher's own duration and looks exactly like "one
        /// pathological file owns the phase" while the instrument is
        /// measuring itself.
        pub var wall_max: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
        pub var work_max: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

        /// Distinct worker slots that entered this region. Bit i = slot i;
        /// slots >= 63 fold into bit 63. Report-only, so the fold is harmless.
        pub var slot_mask: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

        /// Numbers came from sampled entries and are extrapolated, not
        /// measured.
        pub var sampled: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(
            false,
        )

        /// A busy-wait. Real elapsed time, but not work anybody can optimize
        /// by making it faster   only by not spinning. Kept out of the hot
        /// list so it does not crowd out actual bottlenecks.
        pub var idle: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(false)

        /// Set once by the first add_units call, from any worker; the
        /// string has static storage (see add_units).
        pub var unit_label: kairo::std::Atomic<unsafe *const c_char> = kairo::std::Atomic<unsafe *const c_char>(
            &null,
        )

        pub var kids:      cxx::std::unordered_map<cxx::std::string, unsafe *TimeReport::Record>
        pub var kid_order: cxx::std::vector<unsafe *TimeReport::Record>

        pub fn Record(self) { }

        @copy
        fn Record(self, const other: Self) = delete

        @move
        fn Record(self, other: Self) = delete

        pub fn total_ns(const self) -> u64 {
            return self.wall_ns.load(kairo::std::MemoryOrder::relaxed) + self.work_ns.load(
                kairo::std::MemoryOrder::relaxed,
            )
        }

        pub fn calls(const self) -> u64 {
            return self.wall_calls.load(kairo::std::MemoryOrder::relaxed) + self.work_calls.load(
                kairo::std::MemoryOrder::relaxed,
            )
        }

        /// Time in THIS region and not in a child.
        ///
        /// Measured against work when the region ever ran on a worker, and
        /// against wall otherwise. Not against wall+work: for a fanned-out
        /// region the wall portion is the dispatcher sitting in wait_group,
        /// and folding that into "self" would put idle waiting at the top of
        /// the hot list.
        pub fn self_ns(const self) -> u64 {
            const w: u64 = self.work_ns.load(kairo::std::MemoryOrder::relaxed)
            const base: u64 = if w != 0 => w
                              else => self.wall_ns.load(
                                  kairo::std::MemoryOrder::relaxed,
                              )

            const c: u64 = self.child_ns.load(kairo::std::MemoryOrder::relaxed)
            return if c >= base => 0 else => base - c
        }

        /// work / wall. Zero when the region never fanned out.
        pub fn par(const self) -> f64 {
            const wl: u64 = self.wall_ns.load(kairo::std::MemoryOrder::relaxed)
            const wk: u64 = self.work_ns.load(kairo::std::MemoryOrder::relaxed)
            if wl == 0 || wk == 0 {
                return 0.0
            }

            return (wk as f64) / (wl as f64)
        }
    }

    /// ## Trace

    pub struct TraceEvent {
        pub var ts_us:  u64
        pub var dur_us: u64
        pub var rec:    unsafe *const TimeReport::Record
    }

    /// Per-thread trace buffer. Owned by the registry, NOT by the thread, so
    /// a pool worker that exits at shutdown does not take its events with it.
    pub struct ThreadBuf {
        pub var slot:   i32                                      = -1
        pub var events: cxx::std::vector<TimeReport::TraceEvent>
    }

    /// ## Global state

    class Registry {
        pub var mu:   kairo::std::SharedMutex
        pub var all:  cxx::std::vector<unsafe *TimeReport::Record>
        pub var bufs: cxx::std::vector<unsafe *TimeReport::ThreadBuf>
        pub var next_slot: kairo::std::Atomic<i32> = kairo::std::Atomic<i32>(0)
        pub var epoch:     TimeReport::Stamp
        pub var wall_ns:   kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
        pub var running: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(
            false,
        )
    }

    inline static fn reg() -> unsafe *TimeReport::Registry {
        static r: TimeReport::Registry
        return unsafe &r
    }

    struct ThreadState {
        pub var current:       unsafe *TimeReport::Record    = &null
        pub var child_acc:     u64                           = 0
        pub var offload_depth: u32                           = 0
        pub var buf:           unsafe *TimeReport::ThreadBuf = &null
    }

    inline static fn tls() -> unsafe *TimeReport::ThreadState {
        thread s: TimeReport::ThreadState = TimeReport::ThreadState()
        if s.buf == &null {
            s.buf = TimeReport::make_buf()
        }

        return unsafe &s
    }

    static fn make_buf() -> unsafe *TimeReport::ThreadBuf {
        var unsafe *r = TimeReport::reg()
        var unsafe *b = kairo::std::create<TimeReport::ThreadBuf>()
        b->slot = r->next_slot.fetch_add(1, kairo::std::MemoryOrder::relaxed)
        var lk = kairo::std::UniqueLock<kairo::std::SharedMutex>(&r->mu)
        r->bufs.push_back(b)
        return b
    }

    inline static fn enabled_flag() -> unsafe *kairo::std::Atomic<bool> {
        static f: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(false)
        return unsafe &f
    }

    inline static fn trace_flag() -> unsafe *kairo::std::Atomic<bool> {
        static f: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(false)
        return unsafe &f
    }

    /// ThreadPool worker count, reported by the driver. -1 = not told.
    ///
    /// The registry cannot infer this. What it knows is how many threads
    /// RECORDED something, which is a different number and always will be:
    /// the driver thread records, and so does the parse diagnostic flusher,
    /// neither of which is a pool worker. Reporting that as "threads" next to
    /// a --threads=N flag invites exactly the off-by-one it looks like.
    inline static fn pool_size_slot() -> unsafe *kairo::std::Atomic<i32> {
        static n: kairo::std::Atomic<i32> = kairo::std::Atomic<i32>(-1)
        return unsafe &n
    }

    inline static fn now_ns() -> u64 {
        return cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
            cxx::std::chrono::steady_clock::now().time_since_epoch(),
        ).count() as u64
    }

    /// ## Lifecycle

    pub inline static fn enabled() -> bool {
        return TimeReport::enabled_flag()->load(
            kairo::std::MemoryOrder::relaxed,
        )
    }

    pub inline static fn tracing() -> bool {
        return TimeReport::trace_flag()->load(kairo::std::MemoryOrder::relaxed)
    }

    /// Tells the report how many pool workers exist. See pool_size_slot.
    pub static fn set_pool_size(n: i32) {
        TimeReport::pool_size_slot()->store(n, kairo::std::MemoryOrder::relaxed)
    }

    /// Arms the registry. Call BEFORE any work you want measured   regions
    /// entered while disabled are not merely unrecorded, they are free, and
    /// the wall clock the report divides by starts HERE. Anything set up
    /// before this call is invisible AND missing from the denominator, which
    /// silently inflates every percentage.
    pub static fn enable(on: bool, trace: bool = false) {
        var unsafe *r = TimeReport::reg()
        if on && !r->running.load(kairo::std::MemoryOrder::relaxed) {
            r->epoch = cxx::std::chrono::steady_clock::now()
            r->running.store(true, kairo::std::MemoryOrder::relaxed)
        }

        TimeReport::trace_flag()->store(
            on && trace,
            kairo::std::MemoryOrder::relaxed,
        )

        TimeReport::enabled_flag()->store(on, kairo::std::MemoryOrder::release)
    }

    /// Stops the clock the % column is taken against. Idempotent.
    pub static fn finish() {
        var unsafe *r = TimeReport::reg()
        if !r->running.exchange(false, kairo::std::MemoryOrder::relaxed) {
            return
        }

        r->wall_ns.store(
            cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
                cxx::std::chrono::steady_clock::now() - r->epoch,
            ).count() as u64,
            kairo::std::MemoryOrder::relaxed,
        )
    }

    /// ## Region resolution

    /// Interns `name` as a child of the region active on this thread.
    pub static fn region(name: unsafe *const c_char) -> unsafe *TimeReport::Record {
        return TimeReport::region_under(
            TimeReport::tls()->current,
            if name != &null => cxx::std::string(name) else => cxx::std::string("?"),
        )
    }

    pub static fn region(const name: cxx::std::string) -> unsafe *TimeReport::Record {
        return TimeReport::region_under(TimeReport::tls()->current, name)
    }

    /// Interns `name` as a SIBLING of the region active on this thread.
    ///
    /// For a handle that must be resolved from inside a setup scope but
    /// belongs beside it: the Lexer's record is resolved during stream open,
    /// but lex time is not part of opening the stream.
    pub static fn region_beside(name: unsafe *const c_char) -> unsafe *TimeReport::Record {
        var unsafe *cur = TimeReport::tls()->current
        return TimeReport::region_under(
            if cur != &null => cur->parent else => &null,
            if name != &null => cxx::std::string(name) else => cxx::std::string("?"),
        )
    }

    /// Explicit-parent lookup, for a handle that must attach somewhere other
    /// than the caller's current scope.
    pub static fn region_under(parent: unsafe *TimeReport::Record, const name: cxx::std::string)
        -> unsafe *TimeReport::Record {
        var unsafe *r = TimeReport::reg()
        {
            var lk = kairo::std::SharedLock<kairo::std::SharedMutex>(&r->mu)
            var unsafe *kids = if parent != &null => unsafe &parent->kids
                               else => TimeReport::roots_unlocked()
            var it = kids->find(name)
            if it != kids->end() {
                return it->second
            }
        }

        var lk = kairo::std::UniqueLock<kairo::std::SharedMutex>(&r->mu)
        var unsafe *kids = if parent != &null => unsafe &parent->kids
                           else => TimeReport::roots_unlocked()
        var it = kids->find(name)
        if it != kids->end() {
            return it->second
        }

        var unsafe *rec = kairo::std::create<TimeReport::Record>()
        rec->name   = name
        rec->parent = parent
        rec->depth  = if parent != &null => parent->depth + 1 else => 0
        if parent != &null {
            rec->path = parent->path
            rec->path += "."
            rec->path += name
        } else {
            rec->path = name
        }

        (*kids)[name] = rec
        if parent != &null {
            parent->kid_order.push_back(rec)
        } else {
            TimeReport::root_order_unlocked()->push_back(rec)
        }

        r->all.push_back(rec)
        return rec
    }

    /// The region active on this thread, for handing a pool task its record.
    pub inline static fn current() -> unsafe *TimeReport::Record {
        return TimeReport::tls()->current
    }

    /// Marks `rec` a busy-wait. See Record::idle.
    pub static fn mark_idle(rec: unsafe *TimeReport::Record) {
        if rec != &null {
            rec->idle.store(true, kairo::std::MemoryOrder::relaxed)
        }
    }

    /// ## Measurement

    pub struct Frame {
        pub var rec:         unsafe *TimeReport::Record = &null
        pub var parent:      unsafe *TimeReport::Record = &null
        pub var saved_child: u64                        = 0
        pub var t0:          u64                        = 0
        pub var scale:       u32                        = 1     ///< >1 for a sampled entry
        pub var offloaded:   bool                       = false ///< bill to work, not wall
    }

    pub inline static fn enter(rec:   unsafe *TimeReport::Record,
                               scale: u32 = 1) -> TimeReport::Frame {
        var f = TimeReport::Frame()
        if rec == &null {
            return f
        }

        var unsafe *s = TimeReport::tls()
        f.rec         = rec
        f.parent      = s->current
        f.saved_child = s->child_acc
        f.scale       = if scale != 0 => scale else => 1
        f.offloaded   = s->offload_depth != 0
        f.t0          = TimeReport::now_ns()
        s->current    = rec
        s->child_acc  = 0
        return f
    }

    pub inline static fn leave(const f: TimeReport::Frame) {
        if f.rec == &null {
            return
        }

        const t1:  u64 = TimeReport::now_ns()
        const raw: u64 = if t1 > f.t0 => t1 - f.t0 else => 0

        // Sampled: this entry stands in for `scale` of them.
        const dur: u64 = raw * (f.scale as u64)

        var unsafe *s = TimeReport::tls()
        var unsafe *r = f.rec

        var mx: unsafe *kairo::std::Atomic<u64> = &null
        if f.offloaded {
            r->work_ns.fetch_add(dur, kairo::std::MemoryOrder::relaxed)
            r->work_calls.fetch_add(
                f.scale as u64,
                kairo::std::MemoryOrder::relaxed,
            )

            mx = unsafe &r->work_max
        } else {
            r->wall_ns.fetch_add(dur, kairo::std::MemoryOrder::relaxed)
            r->wall_calls.fetch_add(
                f.scale as u64,
                kairo::std::MemoryOrder::relaxed,
            )

            mx = unsafe &r->wall_max
        }

        r->child_ns.fetch_add(s->child_acc, kairo::std::MemoryOrder::relaxed)
        if f.scale > 1 {
            r->sampled.store(true, kairo::std::MemoryOrder::relaxed)
        }

        var prev: u64 = mx->load(kairo::std::MemoryOrder::relaxed)
        while raw > prev
            && !mx->compare_exchange_weak(
                &prev,
                raw,
                kairo::std::MemoryOrder::relaxed,
            ) { }

        const slot: i32 = s->buf->slot
        const bit:  u64 = if slot < 63 => slot as u64 else => 63
        r->slot_mask.fetch_or(
            (1 as u64) << bit,
            kairo::std::MemoryOrder::relaxed,
        )

        // Trace records what actually ran, so it uses the RAW duration and
        // skips sampled entries entirely   a scaled span drawn on a timeline
        // would be a rectangle covering time the region did not occupy.
        if TimeReport::tracing() && f.scale == 1 {
            var unsafe *g = TimeReport::reg()
            const base: u64 = cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
                g->epoch.time_since_epoch(),
            ).count() as u64
            var ev = TimeReport::TraceEvent {
                ts_us:  if f.t0 > base => (f.t0 - base) / 1000 else => (0 as u64),
                dur_us: raw / 1000,
                rec:    r,
            }

            s->buf->events.push_back(ev)
        }

        s->current   = f.parent
        s->child_acc = f.saved_child + dur
    }

    /// Optional throughput counter. `label` is remembered from the first
    /// call and shown in the report as label/s. The POINTER is kept until
    /// the report is printed, so `label` must have static storage (a string
    /// literal, in C++ or in Kairo).
    pub static fn add_units(rec: unsafe *TimeReport::Record, n: u64, label: unsafe *const c_char) {
        if rec == &null {
            return
        }

        var none: unsafe *const c_char = &null
        rec->unit_label.compare_exchange_strong(
            &none,
            label,
            kairo::std::MemoryOrder::relaxed,
        )

        rec->units.fetch_add(n, kairo::std::MemoryOrder::relaxed)
    }

    /// The clock every Frame stamps with, for a caller that has to line up
    /// spans measured by someone else (see record_span).
    pub inline static fn clock_ns() -> u64 {
        return TimeReport::now_ns()
    }

    /// Bills a span that ALREADY HAPPENED on this thread: `dur_ns` starting
    /// at `t0_ns` on clock_ns()'s clock.
    ///
    /// For time another profiler measured   clang's own TimeTraceScopes,
    /// harvested after ExecuteAction returns (ClangTime.k). Those spans ran
    /// inside a region that is still open, so the parent's child time has to
    /// be credited the same way leave() would have: through the thread's
    /// accumulator when the parent is that open region (its leave() folds it
    /// in), directly when the parent is itself a harvested span that will
    /// never leave().
    pub static fn record_span(rec: unsafe *TimeReport::Record, t0_ns: u64, dur_ns: u64) {
        if rec == &null || !TimeReport::enabled() {
            return
        }

        var unsafe *s = TimeReport::tls()

        rec->wall_ns.fetch_add(dur_ns, kairo::std::MemoryOrder::relaxed)
        rec->wall_calls.fetch_add(1, kairo::std::MemoryOrder::relaxed)
        var prev: u64 = rec->wall_max.load(kairo::std::MemoryOrder::relaxed)
        while dur_ns > prev
            && !rec->wall_max.compare_exchange_weak(
                &prev,
                dur_ns,
                kairo::std::MemoryOrder::relaxed,
            ) { }

        const slot: i32 = s->buf->slot
        const bit:  u64 = if slot < 63 => slot as u64 else => 63
        rec->slot_mask.fetch_or(
            (1 as u64) << bit,
            kairo::std::MemoryOrder::relaxed,
        )

        if rec->parent == s->current {
            s->child_acc += dur_ns
        } else if rec->parent != &null {
            rec->parent->child_ns.fetch_add(
                dur_ns,
                kairo::std::MemoryOrder::relaxed,
            )
        }

        if TimeReport::tracing() {
            const base: u64 = cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(
                TimeReport::reg()->epoch.time_since_epoch(),
            ).count() as u64
            var ev = TimeReport::TraceEvent {
                ts_us:  if t0_ns > base => (t0_ns - base) / 1000 else => (0 as u64),
                dur_us: dur_ns / 1000,
                rec:    rec,
            }

            s->buf->events.push_back(ev)
        }
    }

    /// ## POD enter/leave, for the Kairo wrapper
    ///
    ///   Scope and friends are non-copyable and have no default ctor, so they
    ///   cannot be members of a Kairo class. These pass the same state as
    ///   plain values instead. Support/TimeReport.k is the only caller.

    pub struct RootBox {
        pub var saved:       unsafe *TimeReport::Record = &null
        pub var saved_child: u64                        = 0
        pub var armed:       bool                       = false
    }

    pub inline static fn root_enter(parent: unsafe *TimeReport::Record) -> TimeReport::RootBox {
        var b = TimeReport::RootBox()
        if !TimeReport::enabled() {
            return b
        }

        var unsafe *s = TimeReport::tls()
        b.armed       = true
        b.saved       = s->current
        b.saved_child = s->child_acc
        s->current    = parent
        s->child_acc  = 0
        ++s->offload_depth
        return b
    }

    pub inline static fn root_leave(const b: TimeReport::RootBox) {
        if !b.armed {
            return
        }

        var unsafe *s = TimeReport::tls()
        s->current   = b.saved
        s->child_acc = b.saved_child
        if s->offload_depth != 0 {
            --s->offload_depth
        }
    }

    /// A worker entering `rec` to do a slice of it: roots the thread under
    /// rec's parent so nested regions land in the right place, then enters
    /// rec itself with the entry billed to work.
    pub struct WorkerBox {
        pub var root:  TimeReport::RootBox = TimeReport::RootBox()
        pub var frame: TimeReport::Frame   = TimeReport::Frame()
    }

    pub inline static fn worker_enter(rec: unsafe *TimeReport::Record) -> TimeReport::WorkerBox {
        var w = TimeReport::WorkerBox()
        if !TimeReport::enabled() || rec == &null {
            return w
        }

        w.root  = TimeReport::root_enter(rec->parent)
        w.frame = TimeReport::enter(rec)
        return w
    }

    pub inline static fn worker_leave(const w: TimeReport::WorkerBox) {
        TimeReport::leave(w.frame)
        TimeReport::root_leave(w.root)
    }

    /// ## RAII

    /// Scoped region. Checks the enable flag once at construction; when off
    /// it costs one relaxed load and reads no clock.
    pub class Scope {
        var _f: TimeReport::Frame = TimeReport::Frame()

        pub inline fn Scope(self, rec: unsafe *TimeReport::Record) {
            if !TimeReport::enabled() {
                return
            }

            self._f = TimeReport::enter(rec)
        }

        pub inline fn Scope(self, name: unsafe *const c_char) {
            if !TimeReport::enabled() {
                return
            }

            self._f = TimeReport::enter(TimeReport::region(name))
        }

        pub inline fn Scope(self, const name: cxx::std::string) {
            if !TimeReport::enabled() {
                return
            }

            self._f = TimeReport::enter(TimeReport::region(name))
        }

        inline fn op finally (self) {
            TimeReport::leave(self._f)
        }

        @copy
        fn Scope(self, const other: Self) = delete

        @move
        fn Scope(self, other: Self) = delete

        pub inline fn record(const self) -> unsafe *TimeReport::Record {
            return self._f.rec
        }

        pub inline fn units(self, n: u64, label: unsafe *const c_char) {
            TimeReport::add_units(self._f.rec, n, label)
        }
    }

    /// Roots this thread's region stack at `parent` for the scope. Prefer
    /// Worker below unless the task's own time should not be billed
    /// anywhere.
    pub class ThreadRoot {
        var _b: TimeReport::RootBox = TimeReport::RootBox()

        pub inline fn ThreadRoot(self, parent: unsafe *TimeReport::Record) {
            self._b = TimeReport::root_enter(parent)
        }

        inline fn op finally (self) {
            TimeReport::root_leave(self._b)
        }

        @copy
        fn ThreadRoot(self, const other: Self) = delete

        @move
        fn ThreadRoot(self, other: Self) = delete
    }

    /// A pool task doing a slice of `rec`. Open this FIRST in the task.
    pub class Worker {
        var _w: TimeReport::WorkerBox = TimeReport::WorkerBox()

        pub inline fn Worker(self, rec: unsafe *TimeReport::Record) {
            self._w = TimeReport::worker_enter(rec)
        }

        inline fn op finally (self) {
            TimeReport::worker_leave(self._w)
        }

        @copy
        fn Worker(self, const other: Self) = delete

        @move
        fn Worker(self, other: Self) = delete

        pub inline fn units(self, n: u64, label: unsafe *const c_char) {
            TimeReport::add_units(self._w.frame.rec, n, label)
        }
    }

    /// ## Reporting

    /// Writes the aggregate report. `out_in` defaults to stderr, matching
    /// clang's -ftime-report, so it never contaminates -E / --emit output.
    ///
    /// Narrow (fprintf), like every other stderr writer in the compiler:
    /// strings are UTF-8 bytes, and a FILE must never mix wide and narrow
    /// writes (once oriented, the other kind fails silently).
    pub static fn print(out_in: unsafe *cxx::std::FILE = &null) {
        var unsafe *out = if out_in == &null => kairo::std_err() else => out_in
        TimeReport::finish()

        var unsafe *r = TimeReport::reg()
        var        lk = kairo::std::SharedLock<kairo::std::SharedMutex>(&r->mu)

        var wall: u64 = r->wall_ns.load(kairo::std::MemoryOrder::relaxed)
        if wall == 0 {
            for t in *TimeReport::root_order_unlocked() {
                wall += t->total_ns()
            }
        }

        if wall == 0 {
            wall = 1
        }

        cxx::std::fprintf(out, "\n===-%s-===\n", TimeReport::dashes().c_str())
        cxx::std::fprintf(
            out,
            "                          Kairo Compilation Timing Report\n",
        )

        cxx::std::fprintf(out, "===-%s-===\n", TimeReport::dashes().c_str())
        // "pool" is what --threads asked for; "recorded" is every thread that
        // entered a region, which additionally includes the driver and the
        // parse diagnostic flusher. Printing only the latter as "threads"
        // reads like an off-by-one against the flag, because it is not the
        // same quantity.
        const pool: i32 = TimeReport::pool_size_slot()->load(
            kairo::std::MemoryOrder::relaxed,
        )

        if pool >= 0 {
            cxx::std::fprintf(
                out,
                "  run %.3f ms   regions %zu   pool %d   recorded %zu threads\n\n",
                (wall as f64) / 1e6,
                r->all.size(),
                pool,
                r->bufs.size(),
            )
        } else {
            cxx::std::fprintf(
                out,
                "  run %.3f ms   regions %zu   recorded %zu threads\n\n",
                (wall as f64) / 1e6,
                r->all.size(),
                r->bufs.size(),
            )
        }

        cxx::std::fprintf(
            out,
            "  ----wall----   ----work----   ---self---   calls   ----avg----  ----max----  ------rate------  region\n",
        )

        cxx::std::fprintf(
            out,
            "      ms      %%       ms   par        ms                    us           us                      \n",
        )

        var roots = *TimeReport::root_order_unlocked()
        TimeReport::sort_by_total(&roots)
        for t in roots {
            TimeReport::print_node(out, t, wall)
        }

        TimeReport::print_hot(out, wall)

        cxx::std::fprintf(
            out,
            "\n  wall is time on the dispatching thread (latency); work is time summed over\n  pool workers, so it may exceed the run. par = work/wall, the speedup the\n  fan-out achieved. `~` = sampled estimate. [idle] = busy-wait, excluded below.\n",
        )

        cxx::std::fflush(out)
    }

    /// Chrome Trace Event JSON (chrome://tracing, Perfetto, speedscope).
    ///
    /// The report tells you WHICH region is slow; this tells you WHEN, on
    /// WHICH thread, and what was running beside it   the only way to see a
    /// serialized wave, a starved pool, or which single file owns the
    /// critical path.
    pub static fn write_trace(path: unsafe *const c_char) -> bool {
        if path == &null || *path == (0 as c_char) {
            return false
        }

        var unsafe *f = cxx::std::fopen(path, "wb")
        if f == &null {
            return false
        }

        var unsafe *r = TimeReport::reg()
        var        lk = kairo::std::SharedLock<kairo::std::SharedMutex>(&r->mu)

        cxx::std::fprintf(f, "{\"displayTimeUnit\":\"ms\",\"traceEvents\":[\n")
        var first = true

        for b in r->bufs {
            if first {
                first = false
            } else {
                cxx::std::fprintf(f, ",\n")
            }

            cxx::std::fprintf(
                f,
                "{\"ph\":\"M\",\"pid\":1,\"tid\":%d,\"name\":\"thread_name\",\"args\":{\"name\":\"%s\"}}",
                b->slot,
                (if b->slot == 0 => cxx::std::string("driver")
                 else => cxx::std::string("worker")).c_str(),
            )
        }

        for b in r->bufs {
            for ev in b->events {
                if first {
                    first = false
                } else {
                    cxx::std::fprintf(f, ",\n")
                }

                cxx::std::fprintf(
                    f,
                    "{\"ph\":\"X\",\"pid\":1,\"tid\":%d,\"ts\":%llu,\"dur\":%llu,\"name\":\"%s\",\"cat\":\"%s\"}",
                    b->slot,
                    ev.ts_us,
                    ev.dur_us,
                    TimeReport::json_escape(ev.rec->name).c_str(),
                    TimeReport::json_escape(TimeReport::top_of(ev.rec)).c_str(),
                )
            }
        }

        cxx::std::fprintf(f, "\n]}\n")
        // A trace cut short by a write error is not a trace: say so.
        const failed: bool = cxx::std::ferror(f) != 0
        return cxx::std::fclose(f) == 0 && !failed
    }

    inline static fn roots_unlocked() -> unsafe *cxx::std::unordered_map<cxx::std::string, unsafe *TimeReport::Record> {
        static m: cxx::std::unordered_map<cxx::std::string, unsafe *TimeReport::Record>
        return unsafe &m
    }

    inline static fn root_order_unlocked() -> unsafe *cxx::std::vector<unsafe *TimeReport::Record> {
        static v: cxx::std::vector<unsafe *TimeReport::Record>
        return unsafe &v
    }

    static fn dashes() -> cxx::std::string {
        return cxx::std::string(
            "-------------------------------------------------------------------------------------------------",
        )
    }

    static fn total_before(a: unsafe *const TimeReport::Record,
                           b: unsafe *const TimeReport::Record) -> bool {
        return a->total_ns() > b->total_ns()
    }

    static fn self_before(a: unsafe *const TimeReport::Record,
                          b: unsafe *const TimeReport::Record) -> bool {
        return a->self_ns() > b->self_ns()
    }

    static fn sort_by_total(@inout v: cxx::std::vector<unsafe *TimeReport::Record>) {
        cxx::std::sort(v.begin(), v.end(), TimeReport::total_before)
    }

    static fn top_of(r_in: unsafe *const TimeReport::Record) -> cxx::std::string {
        var unsafe *r = r_in
        while r->parent != &null {
            r = r->parent
        }

        return r->name
    }

    static fn json_escape(const s: cxx::std::string) -> cxx::std::string {
        var o = cxx::std::string()
        o.reserve(s.size() + 8)
        for var i: usize = 0; i < s.size(); ++i {
            const c: c_char = s[i]
            const u: u8     = c as u8
            if u == ('"' as u8) || u == ('\\' as u8) {
                o.push_back(('\\' as u8) as c_char)
                o.push_back(c)
            } else if u == ('\n' as u8) {
                o += "\\n"
            } else if u == ('\t' as u8) {
                o += "\\t"
            } else if u < 0x20 {
                // JSON has no raw control characters in a string.
                var esc: [c_char; 8]
                cxx::std::snprintf(unsafe &esc[0], 8, "\\u%04x", u as u32)
                o += unsafe (&esc[0] as unsafe *const c_char)
            } else {
                o.push_back(c)
            }
        }

        return o
    }

    static fn fmt_ms(buf: unsafe *c_char, n: usize, ns: u64) {
        if ns == 0 {
            cxx::std::snprintf(buf, n, "%s", "")
            return
        }

        cxx::std::snprintf(buf, n, "%.2f", (ns as f64) / 1e6)
    }

    static fn print_node(out: unsafe *cxx::std::FILE, rec: unsafe *TimeReport::Record, wall: u64) {
        const wl:    u64 = rec->wall_ns.load(kairo::std::MemoryOrder::relaxed)
        const wk:    u64 = rec->work_ns.load(kairo::std::MemoryOrder::relaxed)
        const self_: u64 = rec->self_ns()
        const calls: u64 = rec->calls()
        const units: u64 = rec->units.load(kairo::std::MemoryOrder::relaxed)
        const base:  u64 = if wk != 0 => wk else => wl

        // Max and avg follow `base`: for a fanned-out region that is the
        // WORKER side, so max answers "slowest single file" rather than
        // "how long the dispatcher waited", and avg divides by the entries
        // that produced base rather than by wall+work calls.
        const mx: u64 = if wk != 0 => rec->work_max.load(
                            kairo::std::MemoryOrder::relaxed,
                        )
                        else => rec->wall_max.load(
                            kairo::std::MemoryOrder::relaxed,
                        )

        const base_calls: u64 = if wk != 0 => rec->work_calls.load(
                                    kairo::std::MemoryOrder::relaxed,
                                )
                                else => rec->wall_calls.load(
                                    kairo::std::MemoryOrder::relaxed,
                                )

        const avg: f64 = if base_calls != 0 => (base as f64) / (base_calls as f64) / 1e3 else => 0.0

        var wall_ms: [c_char; 24]
        var work_ms: [c_char; 24]
        var self_ms: [c_char; 24]
        TimeReport::fmt_ms(unsafe &wall_ms[0], 24, wl)
        TimeReport::fmt_ms(unsafe &work_ms[0], 24, wk)
        TimeReport::fmt_ms(unsafe &self_ms[0], 24, self_)

        var pct: [c_char; 16]
        if wl != 0 {
            cxx::std::snprintf(
                unsafe &pct[0],
                16,
                "%5.1f%%",
                100.0 * (wl as f64) / (wall as f64),
            )
        } else {
            cxx::std::snprintf(unsafe &pct[0], 16, "%6s", "")
        }

        var   parbuf: [c_char; 16]
        const p:      f64          = rec->par()
        if p > 0.0 {
            cxx::std::snprintf(unsafe &parbuf[0], 16, "%5.2fx", p)
        } else {
            cxx::std::snprintf(unsafe &parbuf[0], 16, "%6s", "")
        }

        var rate: [c_char; 32]
        rate[0] = 0 as c_char
        const label = rec->unit_label.load(kairo::std::MemoryOrder::relaxed)
        if units != 0 && label != &null && base != 0 {
            const per_s: f64 = (units as f64) / ((base as f64) / 1e9)
            if per_s >= 1e9 {
                cxx::std::snprintf(
                    unsafe &rate[0],
                    32,
                    "%7.2f G%s/s",
                    per_s / 1e9,
                    label,
                )
            } else if per_s >= 1e6 {
                cxx::std::snprintf(
                    unsafe &rate[0],
                    32,
                    "%7.2f M%s/s",
                    per_s / 1e6,
                    label,
                )
            } else if per_s >= 1e3 {
                cxx::std::snprintf(
                    unsafe &rate[0],
                    32,
                    "%7.2f K%s/s",
                    per_s / 1e3,
                    label,
                )
            } else {
                cxx::std::snprintf(
                    unsafe &rate[0],
                    32,
                    "%7.2f  %s/s",
                    per_s,
                    label,
                )
            }
        }

        var   indent: [c_char; 128]
        const pad:    u32           = if rec->depth * 2 < 100 => rec->depth * 2 else => 100
        cxx::std::memset(unsafe &indent[0], (' ' as u8) as i32, pad as usize)
        indent[pad] = 0 as c_char

        var tag = cxx::std::string()
        if rec->idle.load(kairo::std::MemoryOrder::relaxed) {
            tag = cxx::std::string("  [idle]")
        } else if rec->sampled.load(kairo::std::MemoryOrder::relaxed) {
            tag = cxx::std::string("  ~")
        }

        cxx::std::fprintf(
            out,
            "  %8s %s  %8s %s  %8s %7llu  %10.1f  %10.1f  %-16s  %s%s%s\n",
            unsafe (&wall_ms[0] as unsafe *const c_char),
            unsafe (&pct[0] as unsafe *const c_char),
            unsafe (&work_ms[0] as unsafe *const c_char),
            unsafe (&parbuf[0] as unsafe *const c_char),
            unsafe (&self_ms[0] as unsafe *const c_char),
            calls,
            avg,
            (mx as f64) / 1e3,
            unsafe (&rate[0] as unsafe *const c_char),
            unsafe (&indent[0] as unsafe *const c_char),
            rec->name.c_str(),
            tag.c_str(),
        )

        var kids = rec->kid_order
        TimeReport::sort_by_total(&kids)
        for k in kids {
            TimeReport::print_node(out, k, wall)
        }
    }

    /// Flat top-N by SELF time. The tree tells you where time sits in the
    /// pipeline; this tells you what to go fix. Busy-waits are excluded   a
    /// spinning flusher is a design bug, not a slow function, and it would
    /// otherwise sit at the top of the list forever.
    eval HOT_ROWS:     usize = 15
    eval HOT_FLOOR_NS: u64   = 50000

    static fn print_hot(out: unsafe *cxx::std::FILE, wall: u64) {
        var unsafe *r = TimeReport::reg()
        var v: cxx::std::vector<unsafe *TimeReport::Record>
        for rec in r->all {
            if rec->idle.load(kairo::std::MemoryOrder::relaxed) {
                continue
            }

            // 50us floor. A pure dispatcher's self time is its own
            // bookkeeping and rounds to 0.00 ms; listing those pads the list
            // with rows nobody can act on and pushes real entries off the
            // bottom.
            if rec->self_ns() < TimeReport::HOT_FLOOR_NS {
                continue
            }

            v.push_back(rec)
        }

        cxx::std::sort(v.begin(), v.end(), TimeReport::self_before)

        const n: usize = if v.size() < TimeReport::HOT_ROWS => v.size() else => TimeReport::HOT_ROWS
        if n == 0 {
            return
        }

        cxx::std::fprintf(out, "\n  hottest regions by self time\n")
        for var i: usize = 0; i < n; ++i {
            var unsafe *rec = v[i]
            cxx::std::fprintf(
                out,
                "  %9.2f ms %6.1f%%  %8llu calls  %s%s\n",
                (rec->self_ns() as f64) / 1e6,
                100.0 * (rec->self_ns() as f64) / (wall as f64),
                rec->calls(),
                rec->path.c_str(),
                (if rec->work_ns.load(kairo::std::MemoryOrder::relaxed) != 0 => cxx::std::string(
                     "  [pool]",
                 )
                 else => cxx::std::string()).c_str(),
            )
        }
    }
}

/// # Flat facade
///
///   Support/TimeReport.k binds to THESE, not to TimeReport's nested types:
///   aliases and free functions keep the Kairo side to one namespace hop.
///
///   No logic lives here. Anything that is not a one-line forward belongs on
///   TimeReport.

pub type KTimeRecord = TimeReport::Record
pub type KTimeFrame  = TimeReport::Frame
pub type KTimeRoot   = TimeReport::RootBox
pub type KTimeWorker = TimeReport::WorkerBox

pub inline fn ktime_enable(on: bool, trace: bool) {
    TimeReport::enable(on, trace)
}

pub inline fn ktime_enabled() -> bool {
    return TimeReport::enabled()
}

pub inline fn ktime_finish() {
    TimeReport::finish()
}

pub inline fn ktime_print() {
    TimeReport::print(&null)
}

pub inline fn ktime_write_trace(path: unsafe *const c_char) -> bool {
    return TimeReport::write_trace(path)
}

pub inline fn ktime_region(name: unsafe *const c_char) -> unsafe *KTimeRecord {
    return TimeReport::region(name)
}

pub inline fn ktime_region_beside(name: unsafe *const c_char) -> unsafe *KTimeRecord {
    return TimeReport::region_beside(name)
}

pub inline fn ktime_current() -> unsafe *KTimeRecord {
    return TimeReport::current()
}

pub inline fn ktime_mark_idle(rec: unsafe *KTimeRecord) {
    TimeReport::mark_idle(rec)
}

pub inline fn ktime_set_pool_size(n: i32) {
    TimeReport::set_pool_size(n)
}

pub inline fn ktime_enter(rec: unsafe *KTimeRecord) -> KTimeFrame {
    return TimeReport::enter(rec, 1)
}

pub inline fn ktime_leave(const f: KTimeFrame) {
    TimeReport::leave(f)
}

/// The region clock, or 0 while timing is off (ktime_bill_since then bills
/// nothing). For a span whose variables must outlive any one scope.
pub inline fn ktime_clock() -> u64 {
    return if TimeReport::enabled() => TimeReport::clock_ns() else => 0
}

/// Bills [t0, now) to the child `name` of the region open on this thread.
pub inline fn ktime_bill_since(name: unsafe *const c_char, t0: u64) {
    if t0 == 0 || !TimeReport::enabled() {
        return
    }

    const now: u64 = TimeReport::clock_ns()
    if now <= t0 {
        return
    }

    TimeReport::record_span(TimeReport::region(name), t0, now - t0)
}

/// Sampled entry. Returns an unarmed frame on the (stride-1)/stride of calls
/// that are not sampled, so leave() is a null check.
pub inline fn ktime_enter_sampled(rec:       unsafe *KTimeRecord,
                                  stride_in: u32,
                                  counter:   unsafe *u32) -> KTimeFrame {
    var f = TimeReport::Frame()
    if rec == &null || counter == &null || !TimeReport::enabled() {
        return f
    }

    const stride: u32 = if stride_in < 1 => 1 else => stride_in
    *counter += 1
    if *counter < stride {
        return f
    }

    *counter = 0
    return TimeReport::enter(rec, stride)
}

pub inline fn ktime_units(rec: unsafe *KTimeRecord, n: u64, label: unsafe *const c_char) {
    TimeReport::add_units(rec, n, label)
}

pub inline fn ktime_frame_record(const f: KTimeFrame) -> unsafe *KTimeRecord {
    return f.rec
}

pub inline fn ktime_root_enter(parent: unsafe *KTimeRecord) -> KTimeRoot {
    return TimeReport::root_enter(parent)
}

pub inline fn ktime_root_leave(const b: KTimeRoot) {
    TimeReport::root_leave(b)
}

pub inline fn ktime_worker_enter(rec: unsafe *KTimeRecord) -> KTimeWorker {
    return TimeReport::worker_enter(rec)
}

pub inline fn ktime_worker_leave(const w: KTimeWorker) {
    TimeReport::worker_leave(w)
}

pub inline fn ktime_worker_record(const w: KTimeWorker) -> unsafe *KTimeRecord {
    return w.frame.rec
}
