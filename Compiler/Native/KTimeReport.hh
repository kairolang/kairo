/// --- The Kairo Project ------------------------- Native/KTimeReport.hh --- ///
///
///   Hierarchical, thread-aware pass timing.  The engine behind --time-passes
///   and --time-trace.
///
///   WHY NOT Support/Timer.k: that one prints a line per scope and knows
///   nothing about nesting, aggregation, or other threads.  Useful for a
///   one-off measurement, useless for finding a bottleneck in a pipeline that
///   fans 148 files across a work-stealing pool.
///
///   WHY C++ AND NOT KAIRO: the registry needs thread_local state, atomics and
///   a shared_mutex, and it has to be callable from inside the `inline "c++"`
///   pool lambdas in FrontendAction::_parse   which is exactly where the
///   interesting time goes.  A Kairo-side wrapper lives in
///   Support/TimeReport.k for call sites that are plain Kairo.
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
///   That is why there is no `Parse` / `parse-task` pair of rows.  There was,
///   and it read like a toy: two lines, near-identical names, one number each,
///   and the reader left to divide them.  One row, two columns, the ratio
///   computed for you.
///
///   Other per-record fields:
///     child_ns  inclusive time of children entered on the same thread
///     self_ns   work (or wall, if the region never ran on a worker) - child
///     max_ns    slowest single entry   the one pathological file
///     units     optional throughput counter (bytes, tokens, lines)
///
///   SAMPLING.  A region on a per-token path cannot afford two clock reads per
///   entry: clock_gettime through the vDSO is ~25ns on aarch64, which against
///   a ~20ns tokenizer step measures the measurement.  SampledScope times one
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
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_TOOLCHAIN_CORE_KTIMEREPORT_HH__
#define __KAIRO_TOOLCHAIN_CORE_KTIMEREPORT_HH__

#include <include/core.hh>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace kairo {

class TimeReport {
  public:
    using Clock = libcxx::chrono::steady_clock;
    using Stamp = Clock::time_point;

    // --- Record ----------------------------------------------------------

    /// One named region. Heap-owned by the registry and never freed before
    /// process exit: every Record* handed out stays valid, which is what lets
    /// a hot call site hoist its lookup out of the loop.
    struct Record {
        libcxx::string name;   ///< leaf name
        libcxx::string path;   ///< full dotted path (the identity)
        Record        *parent = nullptr;
        unsigned       depth  = 0;

        /// Dispatching-thread time. Latency.
        libcxx::atomic<uint64_t> wall_ns{0};
        libcxx::atomic<uint64_t> wall_calls{0};

        /// Worker time, summed across every thread that entered under a
        /// TimeWorker. Work.
        libcxx::atomic<uint64_t> work_ns{0};
        libcxx::atomic<uint64_t> work_calls{0};

        libcxx::atomic<uint64_t> child_ns{0};
        libcxx::atomic<uint64_t> units{0};

        /// Slowest single entry, tracked PER KIND.
        ///
        /// One shared max was a bug with teeth. A fanned-out region's wall
        /// entry is the whole dispatch-and-wait, which is by construction
        /// longer than any one worker slice, so a shared max always reported
        /// the dispatcher's own duration and looked exactly like "one
        /// pathological file owns the phase". It read as a finding. It was the
        /// instrument measuring itself.
        libcxx::atomic<uint64_t> wall_max{0};
        libcxx::atomic<uint64_t> work_max{0};

        /// Distinct worker slots that entered this region. Bit i = slot i;
        /// slots >= 63 fold into bit 63. Report-only, so the fold is harmless.
        libcxx::atomic<uint64_t> slot_mask{0};

        /// Numbers came from SampledScope and are extrapolated, not measured.
        libcxx::atomic<bool> sampled{false};

        /// A busy-wait. Real elapsed time, but not work anybody can optimize
        /// by making it faster   only by not spinning. Kept out of the hot
        /// list so it does not crowd out actual bottlenecks.
        libcxx::atomic<bool> idle{false};

        const char *unit_label = nullptr;

        libcxx::unordered_map<libcxx::string, Record *> kids;
        libcxx::vector<Record *>                        kid_order;

        uint64_t total_ns() const {
            return wall_ns.load(libcxx::memory_order_relaxed) +
                   work_ns.load(libcxx::memory_order_relaxed);
        }

        uint64_t calls() const {
            return wall_calls.load(libcxx::memory_order_relaxed) +
                   work_calls.load(libcxx::memory_order_relaxed);
        }

        /// Time in THIS region and not in a child.
        ///
        /// Measured against work when the region ever ran on a worker, and
        /// against wall otherwise. Not against wall+work: for a fanned-out
        /// region the wall portion is the dispatcher sitting in wait_group,
        /// and folding that into "self" would put idle waiting at the top of
        /// the hot list.
        uint64_t self_ns() const {
            const uint64_t w = work_ns.load(libcxx::memory_order_relaxed);
            const uint64_t base = w ? w : wall_ns.load(libcxx::memory_order_relaxed);
            const uint64_t c    = child_ns.load(libcxx::memory_order_relaxed);
            return (c >= base) ? 0 : (base - c);
        }

        /// work / wall. Zero when the region never fanned out.
        double par() const {
            const uint64_t wl = wall_ns.load(libcxx::memory_order_relaxed);
            const uint64_t wk = work_ns.load(libcxx::memory_order_relaxed);
            if (wl == 0 || wk == 0) { return 0.0; }
            return double(wk) / double(wl);
        }
    };

    // --- Trace -----------------------------------------------------------

    struct TraceEvent {
        uint64_t      ts_us;
        uint64_t      dur_us;
        const Record *rec;
    };

    /// Per-thread trace buffer. Owned by the registry, NOT by the thread, so a
    /// pool worker that exits at shutdown does not take its events with it.
    struct ThreadBuf {
        int                        slot = -1;
        libcxx::vector<TraceEvent> events;
    };

    // --- Global state ----------------------------------------------------

  private:
    struct Registry {
        libcxx::shared_mutex        mu;
        libcxx::vector<Record *>    all;
        libcxx::vector<ThreadBuf *> bufs;
        libcxx::atomic<int>         next_slot{0};
        Stamp                       epoch;
        libcxx::atomic<uint64_t>    wall_ns{0};
        libcxx::atomic<bool>        running{false};
    };

    static Registry &reg() {
        static Registry r;
        return r;
    }

    struct ThreadState {
        Record    *current       = nullptr;
        uint64_t   child_acc     = 0;
        unsigned   offload_depth = 0;
        ThreadBuf *buf           = nullptr;
    };

    static ThreadState &tls() {
        static thread_local ThreadState s;
        if (s.buf == nullptr) { s.buf = make_buf(); }
        return s;
    }

    static ThreadBuf *make_buf() {
        Registry  &r = reg();
        ThreadBuf *b = new ThreadBuf();
        b->slot      = r.next_slot.fetch_add(1, libcxx::memory_order_relaxed);
        libcxx::unique_lock<libcxx::shared_mutex> lk(r.mu);
        r.bufs.push_back(b);
        return b;
    }

    static libcxx::atomic<bool> &enabled_flag() {
        static libcxx::atomic<bool> f{false};
        return f;
    }

    static libcxx::atomic<bool> &trace_flag() {
        static libcxx::atomic<bool> f{false};
        return f;
    }

    /// ThreadPool worker count, reported by the driver. -1 = not told.
    ///
    /// The registry cannot infer this. What it knows is how many threads
    /// RECORDED something, which is a different number and always will be:
    /// the driver thread records, and so does the parse diagnostic flusher,
    /// neither of which is a pool worker. Reporting that as "threads" next to
    /// a --threads=N flag invites exactly the off-by-one it looks like.
    static libcxx::atomic<int> &pool_size_slot() {
        static libcxx::atomic<int> n{-1};
        return n;
    }

    static uint64_t now_ns() {
        return uint64_t(libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(
                            Clock::now().time_since_epoch())
                            .count());
    }

  public:
    // --- Lifecycle -------------------------------------------------------

    static bool enabled() { return enabled_flag().load(libcxx::memory_order_relaxed); }
    static bool tracing() { return trace_flag().load(libcxx::memory_order_relaxed); }

    /// Tells the report how many pool workers exist. See pool_size_slot.
    static void set_pool_size(int n) {
        pool_size_slot().store(n, libcxx::memory_order_relaxed);
    }

    /// Arms the registry. Call BEFORE any work you want measured   regions
    /// entered while disabled are not merely unrecorded, they are free, and
    /// the wall clock the report divides by starts HERE. Anything set up
    /// before this call is invisible AND missing from the denominator, which
    /// silently inflates every percentage.
    static void enable(bool on, bool trace = false) {
        Registry &r = reg();
        if (on && !r.running.load(libcxx::memory_order_relaxed)) {
            r.epoch = Clock::now();
            r.running.store(true, libcxx::memory_order_relaxed);
        }
        trace_flag().store(on && trace, libcxx::memory_order_relaxed);
        enabled_flag().store(on, libcxx::memory_order_release);
    }

    /// Stops the clock the % column is taken against. Idempotent.
    static void finish() {
        Registry &r = reg();
        if (!r.running.exchange(false, libcxx::memory_order_relaxed)) { return; }
        r.wall_ns.store(uint64_t(libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(
                                     Clock::now() - r.epoch)
                                     .count()),
                        libcxx::memory_order_relaxed);
    }

    // --- Region resolution -----------------------------------------------

    /// Interns \p name as a child of the region active on this thread.
    static Record *region(const char *name) {
        return region_under(tls().current, libcxx::string(name ? name : "?"));
    }

    static Record *region(const libcxx::string &name) {
        return region_under(tls().current, name);
    }

    /// Interns \p name as a SIBLING of the region active on this thread.
    ///
    /// For a handle that must be resolved from inside a setup scope but
    /// belongs beside it: the Lexer's record is resolved during stream open,
    /// but lex time is not part of opening the stream.
    static Record *region_beside(const char *name) {
        Record *cur = tls().current;
        return region_under(cur ? cur->parent : nullptr,
                            libcxx::string(name ? name : "?"));
    }

    /// Explicit-parent lookup, for a handle that must attach somewhere other
    /// than the caller's current scope.
    static Record *region_under(Record *parent, const libcxx::string &name) {
        Registry &r = reg();
        {
            libcxx::shared_lock<libcxx::shared_mutex> lk(r.mu);
            const auto &kids = parent ? parent->kids : roots_unlocked();
            auto        it   = kids.find(name);
            if (it != kids.end()) { return it->second; }
        }

        libcxx::unique_lock<libcxx::shared_mutex> lk(r.mu);
        auto &kids = parent ? parent->kids : roots_unlocked();
        auto  it   = kids.find(name);
        if (it != kids.end()) { return it->second; }

        Record *rec = new Record();
        rec->name   = name;
        rec->parent = parent;
        rec->depth  = parent ? (parent->depth + 1) : 0;
        rec->path   = parent ? (parent->path + "." + name) : name;
        kids[name]  = rec;
        if (parent) { parent->kid_order.push_back(rec); }
        else        { root_order_unlocked().push_back(rec); }
        r.all.push_back(rec);
        return rec;
    }

    /// The region active on this thread, for handing a pool task its record.
    static Record *current() { return tls().current; }

    /// Marks \p rec a busy-wait. See Record::idle.
    static void mark_idle(Record *rec) {
        if (rec) { rec->idle.store(true, libcxx::memory_order_relaxed); }
    }

    // --- Measurement -----------------------------------------------------

    struct Frame {
        Record  *rec         = nullptr;
        Record  *parent      = nullptr;
        uint64_t saved_child = 0;
        uint64_t t0          = 0;
        uint32_t scale       = 1;      ///< >1 for a sampled entry
        bool     offloaded   = false;  ///< bill to work, not wall
    };

    static Frame enter(Record *rec, uint32_t scale = 1) {
        Frame f;
        if (rec == nullptr) { return f; }
        ThreadState &s = tls();
        f.rec          = rec;
        f.parent       = s.current;
        f.saved_child  = s.child_acc;
        f.scale        = scale ? scale : 1;
        f.offloaded    = (s.offload_depth != 0);
        f.t0           = now_ns();
        s.current      = rec;
        s.child_acc    = 0;
        return f;
    }

    static void leave(const Frame &f) {
        if (f.rec == nullptr) { return; }
        const uint64_t t1  = now_ns();
        const uint64_t raw = (t1 > f.t0) ? (t1 - f.t0) : 0;

        // Sampled: this entry stands in for `scale` of them.
        const uint64_t dur = raw * uint64_t(f.scale);

        ThreadState &s = tls();
        Record      *r = f.rec;

        libcxx::atomic<uint64_t> *mx = nullptr;
        if (f.offloaded) {
            r->work_ns.fetch_add(dur, libcxx::memory_order_relaxed);
            r->work_calls.fetch_add(f.scale, libcxx::memory_order_relaxed);
            mx = &r->work_max;
        } else {
            r->wall_ns.fetch_add(dur, libcxx::memory_order_relaxed);
            r->wall_calls.fetch_add(f.scale, libcxx::memory_order_relaxed);
            mx = &r->wall_max;
        }

        r->child_ns.fetch_add(s.child_acc, libcxx::memory_order_relaxed);
        if (f.scale > 1) { r->sampled.store(true, libcxx::memory_order_relaxed); }

        uint64_t prev = mx->load(libcxx::memory_order_relaxed);
        while (raw > prev &&
               !mx->compare_exchange_weak(prev, raw, libcxx::memory_order_relaxed)) {}

        const int slot = s.buf->slot;
        r->slot_mask.fetch_or(1ull << (slot < 63 ? slot : 63), libcxx::memory_order_relaxed);

        // Trace records what actually ran, so it uses the RAW duration and
        // skips sampled entries entirely   a scaled span drawn on a timeline
        // would be a rectangle covering time the region did not occupy.
        if (tracing() && f.scale == 1) {
            Registry      &g = reg();
            const uint64_t base =
                uint64_t(libcxx::chrono::duration_cast<libcxx::chrono::nanoseconds>(
                             g.epoch.time_since_epoch())
                             .count());
            TraceEvent ev;
            ev.ts_us  = (f.t0 > base) ? ((f.t0 - base) / 1000ull) : 0;
            ev.dur_us = raw / 1000ull;
            ev.rec    = r;
            s.buf->events.push_back(ev);
        }

        s.current   = f.parent;
        s.child_acc = f.saved_child + dur;
    }

    /// Optional throughput counter. \p label is remembered from the first
    /// call and shown in the report as label/s.
    static void add_units(Record *rec, uint64_t n, const char *label) {
        if (rec == nullptr) { return; }
        if (rec->unit_label == nullptr) { rec->unit_label = label; }
        rec->units.fetch_add(n, libcxx::memory_order_relaxed);
    }

    // --- POD enter/leave, for the Kairo wrapper --------------------------
    //
    //   Scope and friends are non-copyable and have no default ctor, so they
    //   cannot be members of a Kairo class. These pass the same state as plain
    //   values instead. Support/TimeReport.k is the only caller.

    struct RootBox {
        Record  *saved       = nullptr;
        uint64_t saved_child = 0;
        bool     armed       = false;
    };

    static RootBox root_enter(Record *parent) {
        RootBox b;
        if (!enabled()) { return b; }
        ThreadState &s = tls();
        b.armed        = true;
        b.saved        = s.current;
        b.saved_child  = s.child_acc;
        s.current      = parent;
        s.child_acc    = 0;
        s.offload_depth++;
        return b;
    }

    static void root_leave(const RootBox &b) {
        if (!b.armed) { return; }
        ThreadState &s = tls();
        s.current      = b.saved;
        s.child_acc    = b.saved_child;
        if (s.offload_depth) { s.offload_depth--; }
    }

    /// A worker entering \p rec to do a slice of it: roots the thread under
    /// rec's parent so nested regions land in the right place, then enters
    /// rec itself with the entry billed to work.
    struct WorkerBox {
        RootBox root;
        Frame   frame;
    };

    static WorkerBox worker_enter(Record *rec) {
        WorkerBox w;
        if (!enabled() || rec == nullptr) { return w; }
        w.root  = root_enter(rec->parent);
        w.frame = enter(rec);
        return w;
    }

    static void worker_leave(const WorkerBox &w) {
        leave(w.frame);
        root_leave(w.root);
    }

    // --- RAII ------------------------------------------------------------

    /// Scoped region. Checks the enable flag once at construction; when off it
    /// costs one relaxed load and reads no clock.
    class Scope {
      public:
        explicit Scope(Record *rec) {
            if (!TimeReport::enabled()) { return; }
            _f = TimeReport::enter(rec);
        }
        explicit Scope(const char *name) {
            if (!TimeReport::enabled()) { return; }
            _f = TimeReport::enter(TimeReport::region(name));
        }
        explicit Scope(const libcxx::string &name) {
            if (!TimeReport::enabled()) { return; }
            _f = TimeReport::enter(TimeReport::region(name));
        }
        ~Scope() { TimeReport::leave(_f); }

        Scope(const Scope &)            = delete;
        Scope &operator=(const Scope &) = delete;

        Record *record() const { return _f.rec; }
        void    units(uint64_t n, const char *label) { TimeReport::add_units(_f.rec, n, label); }

      private:
        Frame _f;
    };

    /// Times one entry in \p stride and multiplies by \p stride.
    ///
    /// For a region on a per-token path, where two clock reads per entry would
    /// cost more than the work being measured. \p counter must be a
    /// thread-local or per-object counter the caller owns; sharing one across
    /// threads costs a cache line per token and defeats the purpose.
    ///
    /// The result is an ESTIMATE. Over millions of entries the sampling error
    /// is far below the resolution anyone acts on, but the row is marked `~`
    /// so nobody quotes it as measured.
    class SampledScope {
      public:
        SampledScope(Record *rec, uint32_t stride, uint32_t &counter) {
            if (rec == nullptr || !TimeReport::enabled()) { return; }
            if (stride < 1) { stride = 1; }
            if (++counter < stride) { return; }
            counter = 0;
            _f      = TimeReport::enter(rec, stride);
        }
        ~SampledScope() { TimeReport::leave(_f); }

        SampledScope(const SampledScope &)            = delete;
        SampledScope &operator=(const SampledScope &) = delete;

      private:
        Frame _f;
    };

    /// Roots this thread's region stack at \p parent for the scope. Prefer
    /// Worker below unless the task's own time should not be billed anywhere.
    class ThreadRoot {
      public:
        explicit ThreadRoot(Record *parent) { _b = TimeReport::root_enter(parent); }
        ~ThreadRoot() { TimeReport::root_leave(_b); }

        ThreadRoot(const ThreadRoot &)            = delete;
        ThreadRoot &operator=(const ThreadRoot &) = delete;

      private:
        RootBox _b;
    };

    /// A pool task doing a slice of \p rec. Open this FIRST in the task.
    class Worker {
      public:
        explicit Worker(Record *rec) { _w = TimeReport::worker_enter(rec); }
        ~Worker() { TimeReport::worker_leave(_w); }

        Worker(const Worker &)            = delete;
        Worker &operator=(const Worker &) = delete;

        void units(uint64_t n, const char *label) { TimeReport::add_units(_w.frame.rec, n, label); }

      private:
        WorkerBox _w;
    };

    // --- Reporting -------------------------------------------------------

    /// Writes the aggregate report. \p out defaults to stderr, matching
    /// clang's -ftime-report, so it never contaminates -E / --emit output.
    static void print(FILE *out = nullptr) {
        if (out == nullptr) { out = stderr; }
        finish();

        Registry                                 &r = reg();
        libcxx::shared_lock<libcxx::shared_mutex> lk(r.mu);

        uint64_t wall = r.wall_ns.load(libcxx::memory_order_relaxed);
        if (wall == 0) {
            for (Record *t : root_order_unlocked()) { wall += t->total_ns(); }
        }
        if (wall == 0) { wall = 1; }

        fprintf(out, "\n===-%s-===\n", dashes());
        fprintf(out, "                          Kairo Compilation Timing Report\n");
        fprintf(out, "===-%s-===\n", dashes());
        // "pool" is what --threads asked for; "recorded" is every thread that
        // entered a region, which additionally includes the driver and the
        // parse diagnostic flusher. Printing only the latter as "threads"
        // reads like an off-by-one against the flag, because it is not the
        // same quantity.
        const int pool = pool_size_slot().load(libcxx::memory_order_relaxed);
        if (pool >= 0) {
            fprintf(out,
                    "  run %.3f ms   regions %zu   pool %d   recorded %zu threads\n\n",
                    double(wall) / 1e6,
                    r.all.size(),
                    pool,
                    r.bufs.size());
        } else {
            fprintf(out,
                    "  run %.3f ms   regions %zu   recorded %zu threads\n\n",
                    double(wall) / 1e6,
                    r.all.size(),
                    r.bufs.size());
        }

        fprintf(out,
                "  ----wall----   ----work----   ---self---   calls   ----avg----  "
                "----max----  ------rate------  region\n");
        fprintf(out,
                "      ms      %%       ms   par        ms                    us    "
                "       us                      \n");

        libcxx::vector<Record *> roots = root_order_unlocked();
        sort_by_total(roots);
        for (Record *t : roots) { print_node(out, t, wall); }

        print_hot(out, wall);

        fprintf(out,
                "\n  wall is time on the dispatching thread (latency); work is time "
                "summed over\n"
                "  pool workers, so it may exceed the run. par = work/wall, the "
                "speedup the\n"
                "  fan-out achieved. `~` = sampled estimate. [idle] = busy-wait, "
                "excluded below.\n");
        fflush(out);
    }

    /// Chrome Trace Event JSON (chrome://tracing, Perfetto, speedscope).
    ///
    /// The report tells you WHICH region is slow; this tells you WHEN, on
    /// WHICH thread, and what was running beside it   the only way to see a
    /// serialized wave, a starved pool, or which single file owns the critical
    /// path.
    static bool write_trace(const char *path) {
        if (path == nullptr || *path == '\0') { return false; }
        FILE *f = fopen(path, "wb");
        if (f == nullptr) { return false; }

        Registry                                 &r = reg();
        libcxx::shared_lock<libcxx::shared_mutex> lk(r.mu);

        fprintf(f, "{\"displayTimeUnit\":\"ms\",\"traceEvents\":[\n");
        bool first = true;

        for (ThreadBuf *b : r.bufs) {
            if (first) { first = false; } else { fprintf(f, ",\n"); }
            fprintf(f,
                    "{\"ph\":\"M\",\"pid\":1,\"tid\":%d,\"name\":\"thread_name\","
                    "\"args\":{\"name\":\"%s\"}}",
                    b->slot,
                    b->slot == 0 ? "driver" : "worker");
        }

        for (ThreadBuf *b : r.bufs) {
            for (const TraceEvent &ev : b->events) {
                if (first) { first = false; } else { fprintf(f, ",\n"); }
                fprintf(f,
                        "{\"ph\":\"X\",\"pid\":1,\"tid\":%d,\"ts\":%llu,\"dur\":%llu,"
                        "\"name\":\"%s\",\"cat\":\"%s\"}",
                        b->slot,
                        (unsigned long long)ev.ts_us,
                        (unsigned long long)ev.dur_us,
                        json_escape(ev.rec->name).c_str(),
                        json_escape(top_of(ev.rec)).c_str());
            }
        }

        fprintf(f, "\n]}\n");
        fclose(f);
        return true;
    }

    /// Drops every record and event. For a long-lived tool (LSP) that reports
    /// per request rather than per process.
    static void reset() {
        Registry                                 &r = reg();
        libcxx::unique_lock<libcxx::shared_mutex> lk(r.mu);
        for (Record *rec : r.all) { delete rec; }
        r.all.clear();
        root_order_unlocked().clear();
        roots_unlocked().clear();
        for (ThreadBuf *b : r.bufs) { b->events.clear(); }
        r.wall_ns.store(0, libcxx::memory_order_relaxed);
        r.epoch = Clock::now();
    }

  private:
    static libcxx::unordered_map<libcxx::string, Record *> &roots_unlocked() {
        static libcxx::unordered_map<libcxx::string, Record *> m;
        return m;
    }

    static libcxx::vector<Record *> &root_order_unlocked() {
        static libcxx::vector<Record *> v;
        return v;
    }

    static const char *dashes() {
        return "--------------------------------------------------------------------"
               "-----------------------------";
    }

    static void sort_by_total(libcxx::vector<Record *> &v) {
        libcxx::sort(v.begin(), v.end(), [](const Record *a, const Record *b) {
            return a->total_ns() > b->total_ns();
        });
    }

    static libcxx::string top_of(const Record *r) {
        while (r->parent != nullptr) { r = r->parent; }
        return r->name;
    }

    static libcxx::string json_escape(const libcxx::string &s) {
        libcxx::string o;
        o.reserve(s.size() + 8);
        for (char c : s) {
            if (c == '"' || c == '\\') { o.push_back('\\'); o.push_back(c); }
            else if (c == '\n')        { o += "\\n"; }
            else if (c == '\t')        { o += "\\t"; }
            else                       { o.push_back(c); }
        }
        return o;
    }

    static void fmt_ms(char *buf, size_t n, uint64_t ns) {
        if (ns == 0) { snprintf(buf, n, "%s", ""); return; }
        snprintf(buf, n, "%.2f", double(ns) / 1e6);
    }

    static void print_node(FILE *out, Record *rec, uint64_t wall) {
        const uint64_t wl    = rec->wall_ns.load(libcxx::memory_order_relaxed);
        const uint64_t wk    = rec->work_ns.load(libcxx::memory_order_relaxed);
        const uint64_t self  = rec->self_ns();
        const uint64_t calls = rec->calls();
        const uint64_t units = rec->units.load(libcxx::memory_order_relaxed);
        const uint64_t base  = wk ? wk : wl;

        // Max and avg follow `base`: for a fanned-out region that is the
        // WORKER side, so max answers "slowest single file" rather than
        // "how long the dispatcher waited", and avg divides by the entries
        // that produced base rather than by wall+work calls.
        const uint64_t mx = wk ? rec->work_max.load(libcxx::memory_order_relaxed)
                               : rec->wall_max.load(libcxx::memory_order_relaxed);
        const uint64_t base_calls =
            wk ? rec->work_calls.load(libcxx::memory_order_relaxed)
               : rec->wall_calls.load(libcxx::memory_order_relaxed);
        const double avg = base_calls ? (double(base) / double(base_calls) / 1e3) : 0.0;

        char wall_ms[24], work_ms[24], self_ms[24];
        fmt_ms(wall_ms, sizeof(wall_ms), wl);
        fmt_ms(work_ms, sizeof(work_ms), wk);
        fmt_ms(self_ms, sizeof(self_ms), self);

        char pct[16];
        if (wl) { snprintf(pct, sizeof(pct), "%5.1f%%", 100.0 * double(wl) / double(wall)); }
        else    { snprintf(pct, sizeof(pct), "%6s", ""); }

        char parbuf[16];
        const double p = rec->par();
        if (p > 0.0) { snprintf(parbuf, sizeof(parbuf), "%5.2fx", p); }
        else         { snprintf(parbuf, sizeof(parbuf), "%6s", ""); }

        char rate[32];
        rate[0] = '\0';
        if (units && rec->unit_label && base) {
            const double per_s = double(units) / (double(base) / 1e9);
            if (per_s >= 1e9)      { snprintf(rate, sizeof(rate), "%7.2f G%s/s", per_s / 1e9, rec->unit_label); }
            else if (per_s >= 1e6) { snprintf(rate, sizeof(rate), "%7.2f M%s/s", per_s / 1e6, rec->unit_label); }
            else if (per_s >= 1e3) { snprintf(rate, sizeof(rate), "%7.2f K%s/s", per_s / 1e3, rec->unit_label); }
            else                   { snprintf(rate, sizeof(rate), "%7.2f  %s/s", per_s,       rec->unit_label); }
        }

        char indent[128];
        const unsigned pad = rec->depth * 2u < 100u ? rec->depth * 2u : 100u;
        memset(indent, ' ', pad);
        indent[pad] = '\0';

        const char *tag = rec->idle.load(libcxx::memory_order_relaxed)      ? "  [idle]"
                          : rec->sampled.load(libcxx::memory_order_relaxed) ? "  ~"
                                                                            : "";

        fprintf(out,
                "  %8s %s  %8s %s  %8s %7llu  %10.1f  %10.1f  %-16s  %s%s%s\n",
                wall_ms,
                pct,
                work_ms,
                parbuf,
                self_ms,
                (unsigned long long)calls,
                avg,
                double(mx) / 1e3,
                rate,
                indent,
                rec->name.c_str(),
                tag);

        libcxx::vector<Record *> kids = rec->kid_order;
        sort_by_total(kids);
        for (Record *k : kids) { print_node(out, k, wall); }
    }

    /// Flat top-N by SELF time. The tree tells you where time sits in the
    /// pipeline; this tells you what to go fix. Busy-waits are excluded   a
    /// spinning flusher is a design bug, not a slow function, and it would
    /// otherwise sit at the top of the list forever.
    static void print_hot(FILE *out, uint64_t wall) {
        Registry                &r = reg();
        libcxx::vector<Record *> v;
        for (Record *rec : r.all) {
            if (rec->idle.load(libcxx::memory_order_relaxed)) { continue; }
            // 50us floor. A pure dispatcher's self time is its own bookkeeping
            // and rounds to 0.00 ms; listing those pads the list with rows
            // nobody can act on and pushes real entries off the bottom.
            if (rec->self_ns() < 50000ull) { continue; }
            v.push_back(rec);
        }
        libcxx::sort(v.begin(), v.end(), [](const Record *a, const Record *b) {
            return a->self_ns() > b->self_ns();
        });

        const size_t n = v.size() < 15 ? v.size() : 15;
        if (n == 0) { return; }

        fprintf(out, "\n  hottest regions by self time\n");
        for (size_t i = 0; i < n; ++i) {
            Record *rec = v[i];
            fprintf(out,
                    "  %9.2f ms %6.1f%%  %8llu calls  %s%s\n",
                    double(rec->self_ns()) / 1e6,
                    100.0 * double(rec->self_ns()) / double(wall),
                    (unsigned long long)rec->calls(),
                    rec->path.c_str(),
                    rec->work_ns.load(libcxx::memory_order_relaxed) ? "  [pool]" : "");
        }
    }
};

// --- Flat facade ---------------------------------------------------------
//
//   Support/TimeReport.k binds to THESE, not to TimeReport's nested types.
//   Stage0 has to be able to spell every type it touches, and
//   `kairo::TimeReport::Frame` is three levels of qualification into a class
//   body. Aliases and free functions keep the Kairo side to one namespace hop.
//
//   No logic lives here. Anything that is not a one-line forward belongs on
//   TimeReport, where the C++ call sites can reach it too.

using KTimeRecord = TimeReport::Record;
using KTimeFrame  = TimeReport::Frame;
using KTimeRoot   = TimeReport::RootBox;
using KTimeWorker = TimeReport::WorkerBox;

inline void ktime_enable(bool on, bool trace) { TimeReport::enable(on, trace); }
inline bool ktime_enabled()                   { return TimeReport::enabled(); }
inline void ktime_finish()                    { TimeReport::finish(); }
inline void ktime_print()                     { TimeReport::print(nullptr); }

inline bool ktime_write_trace(const char *path) { return TimeReport::write_trace(path); }

inline KTimeRecord *ktime_region(const char *name)        { return TimeReport::region(name); }
inline KTimeRecord *ktime_region_beside(const char *name) { return TimeReport::region_beside(name); }
inline KTimeRecord *ktime_current()                       { return TimeReport::current(); }

inline void ktime_mark_idle(KTimeRecord *rec) { TimeReport::mark_idle(rec); }
inline void ktime_set_pool_size(int n)        { TimeReport::set_pool_size(n); }

inline KTimeFrame ktime_enter(KTimeRecord *rec)    { return TimeReport::enter(rec, 1); }
inline void       ktime_leave(const KTimeFrame &f) { TimeReport::leave(f); }

/// Sampled entry. Returns an unarmed frame on the (stride-1)/stride of calls
/// that are not sampled, so leave() is a null check.
inline KTimeFrame ktime_enter_sampled(KTimeRecord *rec, uint32_t stride, uint32_t *counter) {
    KTimeFrame f;
    if (rec == nullptr || counter == nullptr || !TimeReport::enabled()) { return f; }
    if (stride < 1) { stride = 1; }
    if (++(*counter) < stride) { return f; }
    *counter = 0;
    return TimeReport::enter(rec, stride);
}

inline void ktime_units(KTimeRecord *rec, uint64_t n, const char *label) {
    TimeReport::add_units(rec, n, label);
}

inline KTimeRecord *ktime_frame_record(const KTimeFrame &f) { return f.rec; }

inline KTimeRoot ktime_root_enter(KTimeRecord *parent) { return TimeReport::root_enter(parent); }
inline void      ktime_root_leave(const KTimeRoot &b)  { TimeReport::root_leave(b); }

inline KTimeWorker ktime_worker_enter(KTimeRecord *rec)   { return TimeReport::worker_enter(rec); }
inline void        ktime_worker_leave(const KTimeWorker &w) { TimeReport::worker_leave(w); }
inline KTimeRecord *ktime_worker_record(const KTimeWorker &w) { return w.frame.rec; }

}  // namespace kairo

/// Scoped region inside an `inline "c++"` block.
///
///     KTIME("Parse.lower");
#define KTIME_CAT2(a, b) a##b
#define KTIME_CAT(a, b)  KTIME_CAT2(a, b)
#define KTIME(name)      ::kairo::TimeReport::Scope KTIME_CAT(_ktime_, __LINE__)(name)

/// Same, against a hoisted Record* so the hot path does no map lookup.
#define KTIME_REC(rec) ::kairo::TimeReport::Scope KTIME_CAT(_ktime_, __LINE__)(rec)

/// A pool task doing a slice of \p rec. Put this first in the task body.
#define KTIME_WORKER(rec) ::kairo::TimeReport::Worker KTIME_CAT(_ktwork_, __LINE__)(rec)

/// Roots the thread under \p parent without billing the task itself.
#define KTIME_ROOT(parent) \
    ::kairo::TimeReport::ThreadRoot KTIME_CAT(_ktroot_, __LINE__)(parent)

#endif  // __KAIRO_TOOLCHAIN_CORE_KTIMEREPORT_HH__
