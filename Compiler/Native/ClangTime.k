/// --- The Kairo Project --------------------------- Native/ClangTime.k --- ///
///
///   Folds clang's own phase timing into the --time-passes tree.
///
///   Codegen hands clang one EmitObjAction per TU, and from the outside that
///   is a single opaque call: parse and sema of the emitted C++, IR
///   generation, the optimizer and machine code emission all land in one row.
///   Clang already brackets each of those with an llvm::TimeTraceScope, so
///   rather than patch clang this arms LLVM's time-trace profiler on the
///   calling thread for the duration of ExecuteAction, then harvests the few
///   scopes worth a row and bills them under the region that is open there.
///
///   WHAT IS KEPT. Deliberately coarse   this is not -ftime-report:
///
///       TUSetup       clang's instance setup before the Kairo fill (file and
///                     source managers, preprocessor, target); the Kairo side
///                     of a TU's setup bills the same row (CodegenBackend.k)
///       PCHLoad       from the end of the fill to ParseAST: AST context and
///                     consumer, the implicit PCH (clang's "ReadAST", a child
///                     row), Sema, and StartTranslationUnit's eager decls
///                     (their "CodeGen Function" is a child SSALowering row)
///       Emission      ParseAST's "Frontend": parse + sema of the C++
///         SSALowering "CodeGen Function" emitted decl-at-a-time while parsing
///       SSALowering   BackendConsumer's "Frontend": deferred decls, finalize
///       Optimize      "Optimizer" (the new-PM module pipeline)
///       MachineCode   "CodeGenPasses" (ISel through object emission)
///       TUTeardown    after the last span: EndSourceFile freeing the AST
///       ClangTrace    this harvest itself, marked idle
///
///   Clang names two different scopes "Frontend". The one opened by
///   BackendConsumer::HandleTranslationUnit is always the LAST to start,
///   since ParseAST calls HandleTranslationUnit after its own scope closes;
///   that ordering is what tells them apart.
///
///   GRANULARITY. 50 us, not 0. The profiler's write() holds LLVM's
///   one process-wide instance lock for the whole serialization, and the
///   cleanup takes it too, so every worker's harvest queues behind every
///   other's. At granularity 0 a TU averages ~86k events (every pass on
///   every function; 27 M over the self-build), and a sampled --time-passes
///   build had 81% of its codegen workers waiting on that lock: the "idle"
///   gaps between TUs in the trace were this harvest. At 50 us the build
///   writes 43x fewer events and the SSALowering-inside-parse row keeps
///   99.5% of its time (the dropped functions stay in the parse row's self
///   time). No "Frontend" scope of the self-build is under 500 us. A dropped
///   "Optimizer" / "CodeGenPasses" is not lost: the profiler keeps an exact
///   "Total <name>" for every name whatever the threshold, and the
///   difference is billed as one span. A dropped "ReadAST" stays in the
///   PCHLoad row's self time.
///
///   WHY THE JSON. TimeTraceProfiler keeps its entries private; the only
///   public way out is timeTraceProfilerWrite. It is read back by a scanner
///   (detail::scan_trace), not llvm::json::parse.
///
///   THREADING. The profiler instance is thread_local, so only the thread
///   running ExecuteAction records; HeaderSet builds on pool workers see no
///   instance and their scopes stay free. If something else already armed a
///   profiler on this thread, begin() leaves it alone and nothing is
///   harvested. The fill marks (ktime_clang_mark_fill_*) are per-thread
///   too: the fill runs on the thread that called ExecuteAction.
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
ffi "c++" import "Native/Types.hh" // sref, Atomic
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/Support/TimeProfiler.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "algorithm"
ffi "c++" import "atomic"
ffi "c++" import "cstdio"
ffi "c++" import "cstdlib"
ffi "c++" import "string"
ffi "c++" import "vector"

import Native::Progress::ProgressMeter
import Native::TimeReport::TimeReport
import std::c_char

pub module detail {
    /// The cursor of scan_trace over one trace document. Its methods are the
    /// scanner's steps over the shared position `p`.
    class TraceScan {
        var p: unsafe *const u8
        var e: unsafe *const u8

        fn ws(self) {
            while self.p < self.e
                && (*self.p == (' ' as u8)
                    || *self.p == ('\n' as u8)
                    || *self.p == ('\r' as u8)
                    || *self.p == ('\t' as u8)
                    || *self.p == (',' as u8)) {
                self.p += 1
            }
        }

        /// A string at p (p on its opening quote); its raw bytes, escapes
        /// kept.
        fn str(self, @inout out: llvm::StringRef) -> bool {
            if self.p >= self.e || *self.p != ('"' as u8) {
                return false
            }

            self.p += 1
            var unsafe *b = self.p
            while self.p < self.e && *self.p != ('"' as u8) {
                self.p += if *self.p == ('\\' as u8) => 2 else => 1
            }

            if self.p >= self.e {
                return false
            }

            out = llvm::StringRef(
                unsafe (b as unsafe *const c_char),
                (self.p - b) as usize,
            )

            self.p += 1
            return true
        }

        /// Any value that is not read: a string, number, literal, or a
        /// nested object / array (balanced, strings honoured).
        fn skip(self) -> bool {
            if self.p >= self.e {
                return false
            }

            if *self.p == ('"' as u8) {
                var s = llvm::StringRef()
                return self.str(&s)
            }

            if *self.p == ('{' as u8) || *self.p == ('[' as u8) {
                var depth: i32 = 0
                while self.p < self.e {
                    const c: u8 = *self.p
                    if c == ('"' as u8) {
                        var s = llvm::StringRef()
                        if !self.str(&s) {
                            return false
                        }

                        continue
                    }

                    if c == ('{' as u8) || c == ('[' as u8) {
                        ++depth
                    }

                    if c == ('}' as u8) || c == (']' as u8) {
                        --depth
                        if depth == 0 {
                            self.p += 1
                            return true
                        }
                    }

                    self.p += 1
                }

                return false
            }

            while self.p < self.e
                && *self.p != (',' as u8)
                && *self.p != ('}' as u8)
                && *self.p != (']' as u8) {
                self.p += 1
            }

            return true
        }

        fn num(self, @inout out: i64) -> bool {
            const neg: bool = self.p < self.e && *self.p == ('-' as u8)
            if neg {
                self.p += 1
            }

            if self.p >= self.e || *self.p < ('0' as u8) || *self.p > ('9' as u8) {
                return self.skip()
            }

            var v: i64 = 0
            while self.p < self.e && *self.p >= ('0' as u8) && *self.p <= ('9' as u8) {
                v = v * 10 + ((*self.p - ('0' as u8)) as i64)
                self.p += 1
            }

            if self.p < self.e
                && (*self.p == ('.' as u8) || *self.p == ('e' as u8) || *self.p == ('E' as u8)) {
                self.skip()
            }

            out = if neg => -v else => v
            return true
        }
    }

    /// The complete events ("ph":"X") of chrome trace JSON `doc`, in
    /// document order: f(name, ts, dur), ts and dur in us (-1 when missing).
    ///
    /// A scanner, not llvm::json::parse: the document of one big TU at
    /// granularity 0 holds ~13k events (every pass on every function), and
    /// building the DOM for it costs ~70 ms where reading the four names
    /// that matter costs ~1 ms. It only needs what the writer emits: one
    /// array of flat event objects, whose "args" (an object) is skipped.
    /// Keys are matched in any order. Malformed input stops the scan; the
    /// rows then miss what came after, nothing worse.
    pub fn scan_trace(doc: llvm::StringRef, f: fn(llvm::StringRef, i64, i64)) {
        var sc = TraceScan { p: doc.bytes_begin(), e: doc.bytes_begin() + doc.size() }

        const at: usize = doc.find(kairo::sref("\"traceEvents\""))
        if at == llvm::StringRef::npos {
            return
        }

        sc.p += at + 13
        while sc.p < sc.e && *sc.p != ('[' as u8) {
            sc.p += 1
        }

        if sc.p >= sc.e {
            return
        }

        sc.p += 1
        loop {
            sc.ws()
            if sc.p >= sc.e || *sc.p == (']' as u8) {
                return
            }

            if *sc.p != ('{' as u8) {
                return
            }

            sc.p += 1
            var name     = llvm::StringRef()
            var ph       = llvm::StringRef()
            var ts:  i64 = -1
            var dur: i64 = -1
            loop {
                sc.ws()
                if sc.p >= sc.e {
                    return
                }

                if *sc.p == ('}' as u8) {
                    sc.p += 1
                    break
                }

                var key = llvm::StringRef()
                if !sc.str(&key) {
                    return
                }

                sc.ws()
                if sc.p >= sc.e || *sc.p != (':' as u8) {
                    return
                }

                sc.p += 1
                sc.ws()
                var ok = true
                if key == kairo::sref("name") {
                    ok = sc.str(&name)
                } else if key == kairo::sref("ph") {
                    ok = sc.str(&ph)
                } else if key == kairo::sref("ts") {
                    ok = sc.num(&ts)
                } else if key == kairo::sref("dur") {
                    ok = sc.num(&dur)
                } else {
                    ok = sc.skip()
                }

                if !ok {
                    return
                }
            }

            if ph == kairo::sref("X") {
                f(name, ts, dur)
            }
        }
    }

    /// When the Kairo fill began and ended on this thread, for the TU whose
    /// capture is armed here. Set from KairoInject (CodegenAction.k), read
    /// and cleared by ktime_clang_end.
    pub struct KClangFillMarks {
        pub var begin_ns: u64  = 0
        pub var end_ns:   u64  = 0
        pub var armed:    bool = false
    }

    pub inline fn clang_fill_marks() -> unsafe *KClangFillMarks {
        thread m: KClangFillMarks = KClangFillMarks()
        return unsafe &m
    }
}

/// What begin() hands end(). Plain data so the Kairo side can hold it in a
/// `var` across the ExecuteAction call.
pub struct KClangTimeCapture {
    pub var anchor_ns: u64  = 0     ///< TimeReport clock at profiler start
    pub var armed:     bool = false ///< false: timing off, or a profiler was already live
}

/// Below this a clang scope keeps only its "Total" (see GRANULARITY above).
pub eval kClangTraceGranularityUs: u32 = 50

/// Arms LLVM's profiler on this thread. Call immediately before
/// ExecuteAction, while the region the spans belong under is open.
pub fn ktime_clang_begin() -> KClangTimeCapture {
    var c = KClangTimeCapture()
    // Armed for --time-passes and for the progress display's stages.
    if !(TimeReport::enabled() || ProgressMeter::wants_stages())
        || llvm::timeTraceProfilerEnabled() {
        return c
    }

    llvm::timeTraceProfilerInitialize(
        kClangTraceGranularityUs,
        kairo::sref("kairo"),
    )

    // The profiler's `ts` is microseconds since its own construction, on the
    // same steady clock TimeReport stamps with. Taking the anchor right after
    // lines the two up to within the cost of this call.
    c.anchor_ns = TimeReport::clock_ns()
    c.armed     = true
    *detail::clang_fill_marks() = detail::KClangFillMarks { begin_ns: 0, end_ns: 0, armed: true }
    return c
}

/// The Kairo fill of the armed TU starts (BeginSourceFileAction). No-op
/// unless a capture is armed on this thread.
pub fn ktime_clang_mark_fill_begin() {
    var unsafe *m = detail::clang_fill_marks()
    if m->armed {
        m->begin_ns = TimeReport::clock_ns()
    }
}

/// The Kairo fill of the armed TU is done: its stream is in the preprocessor.
pub fn ktime_clang_mark_fill_end() {
    var unsafe *m = detail::clang_fill_marks()
    if m->armed {
        m->end_ns = TimeReport::clock_ns()
    }
}

/// One scope clang kept, in us of the profiler's clock.
struct Span {
    var ts:  u64
    var dur: u64
}

fn span_before(const a: Span, const b: Span) -> bool {
    return a.ts < b.ts
}

/// TimeReport's clock at `us` on the profiler's clock.
fn at_ns(const c: KClangTimeCapture, us: u64) -> u64 {
    return c.anchor_ns + us * 1000
}

fn bill(const c: KClangTimeCapture, rec: unsafe *TimeReport::Record, const s: Span) {
    TimeReport::record_span(rec, at_ns(c, s.ts), s.dur * 1000)
}

/// The outermost "CodeGen Function" spans inside [lo, hi) (us), each billed
/// to `r`, created under `parent` on first use.
fn bill_irgen(const c:   KClangTimeCapture,
              const fns: cxx::std::vector<Span>,
              parent:    unsafe *TimeReport::Record,
              @inout r:  unsafe *TimeReport::Record,
              lo:        u64,
              hi:        u64) {
    var last: u64 = 0 // end of the last billed function: skip nested ones
    for f in fns {
        if f.ts < lo || (f.ts + f.dur) > hi {
            continue
        }

        if f.ts < last {
            continue
        }

        if r == &null {
            r = TimeReport::region_under(
                parent,
                cxx::std::string("SSALowering"),
            )
        }

        bill(c, r, f)
        last = f.ts + f.dur
    }
}

/// Kept spans, then what the granularity dropped (the "Total" exceeds what
/// was kept) as one span after the last one kept.
fn bill_all(const c:  KClangTimeCapture,
            at:       unsafe *TimeReport::Record,
            row:      llvm::StringRef,
            const v:  cxx::std::vector<Span>,
            total:    u64,
            last_end: u64) {
    var kept: u64                        = 0
    var end:  u64                        = last_end
    var r:    unsafe *TimeReport::Record = &null
    for s in v {
        if r == &null {
            r = TimeReport::region_under(at, row.str())
        }

        bill(c, r, s)
        kept += s.dur
        end = s.ts + s.dur
    }

    if total > kept {
        if r == &null {
            r = TimeReport::region_under(at, row.str())
        }

        bill(c, r, Span { ts: end, dur: total - kept })
    }
}

/// Disarms the profiler and bills what clang measured under the region
/// active on this thread. Call right after ExecuteAction, before that region
/// closes.
pub fn ktime_clang_end(const c: KClangTimeCapture) {
    if !c.armed {
        return
    }

    const harvest_ns: u64 = TimeReport::clock_ns()      // ExecuteAction has returned
    const marks           = *detail::clang_fill_marks()
    *detail::clang_fill_marks() = detail::KClangFillMarks()

    var buf = llvm::SmallString<0>()
    {
        var os = llvm::raw_svector_ostream(&buf)
        llvm::timeTraceProfilerWrite(&os)
    }

    llvm::timeTraceProfilerCleanup()

    // KAIRO_CLANG_TRACE_DIR: keep each TU's raw clang trace (chrome JSON) as
    // <dir>/<n>.json, for finding what clang spends a TU's frontend on.
    const dir = cxx::std::getenv("KAIRO_CLANG_TRACE_DIR")
    if dir != &null {
        static n:   kairo::std::Atomic<u32> = kairo::std::Atomic<u32>(0)
        var    path                         = cxx::std::string(dir)
        path += "/"
        path += cxx::std::to_string(n.fetch_add(1))
        path += ".json"
        var unsafe *f = cxx::std::fopen(path.c_str(), "wb")
        if f != &null {
            cxx::std::fwrite(buf.data(), 1, buf.size(), f)
            cxx::std::fclose(f)
        }
    }

    var fe:       cxx::std::vector<Span>
    var fns:      cxx::std::vector<Span>
    var opt:      cxx::std::vector<Span>
    var mc:       cxx::std::vector<Span>
    var rd:       cxx::std::vector<Span>
    var last_end: u64                    = 0 // us: end of the last span clang kept
    var tot_opt:  u64                    = 0 // us: "Total <name>", every scope of the name
    var tot_mc:   u64                    = 0

    // Exact names only: the profiler also writes a "Total <name>" summary per
    // name at ts 0, read here for what the granularity dropped.
    detail::scan_trace(
        buf.str(),
        fn (name: llvm::StringRef, ts: i64, dur: i64)|*fe, *fns, *opt, *mc, *rd, *last_end, *tot_opt, *tot_mc| {
            if ts < 0 || dur < 0 {
                return
            }

            if name.starts_with(kairo::sref("Total ")) {
                const base = name.drop_front(6)
                if base == kairo::sref("Optimizer") {
                    *tot_opt = dur as u64
                } else if base == kairo::sref("CodeGenPasses") {
                    *tot_mc = dur as u64
                }

                return
            }

            const s = Span { ts: ts as u64, dur: dur as u64 }
            if s.ts + s.dur > *last_end {
                *last_end = s.ts + s.dur
            }

            if name == kairo::sref("Frontend") {
                fe->push_back(s)
            } else if name == kairo::sref("CodeGen Function") {
                fns->push_back(s)
            } else if name == kairo::sref("Optimizer") {
                opt->push_back(s)
            } else if name == kairo::sref("CodeGenPasses") {
                mc->push_back(s)
            } else if name == kairo::sref("ReadAST") {
                rd->push_back(s)
            }
        },
    )

    cxx::std::sort(fe.begin(), fe.end(), span_before)
    cxx::std::sort(fns.begin(), fns.end(), span_before)

    // The progress display's stages: IR generation is the outermost
    // "CodeGen Function" spans plus the finishing "Frontend" span, as billed
    // below; the optimizer and the code generator are their "Total".
    if ProgressMeter::wants_stages() {
        var irgen_us: u64 = if fe.empty() => 0 else => fe.back().dur
        var last:     u64 = 0
        for f in fns {
            if f.ts < last {
                continue
            }

            irgen_us += f.dur
            last = f.ts + f.dur
        }

        ProgressMeter::stage(ProgressMeter::IRGen, irgen_us * 1000)

        ProgressMeter::stage(ProgressMeter::Opt, tot_opt * 1000)

        ProgressMeter::stage(ProgressMeter::Emit, tot_mc * 1000)
    }

    if !TimeReport::enabled() {
        return
    }

    var unsafe *at = TimeReport::current()

    // Clang's own setup before the fill: from the anchor (ExecuteAction's
    // start) to BeginSourceFileAction.
    if marks.begin_ns > c.anchor_ns {
        TimeReport::record_span(
            TimeReport::region_under(at, cxx::std::string("TUSetup")),
            c.anchor_ns,
            marks.begin_ns - c.anchor_ns,
        )
    }

    // From the fill's end to ParseAST: the PCH and everything built on it.
    if marks.end_ns != 0 && !fe.empty() && at_ns(c, fe.front().ts) > marks.end_ns {
        const lo_ns: u64 = marks.end_ns
        const hi_ns: u64 = at_ns(c, fe.front().ts)
        var unsafe *r_pch = TimeReport::region_under(
            at,
            cxx::std::string("PCHLoad"),
        )

        TimeReport::record_span(r_pch, lo_ns, hi_ns - lo_ns)
        const lo_us: u64                        = (lo_ns - c.anchor_ns) / 1000
        const hi_us: u64                        = fe.front().ts
        var   r_rd:  unsafe *TimeReport::Record = &null
        for s in rd {
            if s.ts < lo_us || (s.ts + s.dur) > hi_us {
                continue
            }

            if r_rd == &null {
                r_rd = TimeReport::region_under(
                    r_pch,
                    cxx::std::string("ReadAST"),
                )
            }

            bill(c, r_rd, s)
        }

        var r_eager: unsafe *TimeReport::Record = &null
        bill_irgen(c, fns, r_pch, &r_eager, lo_us, hi_us)
    }

    // Every "Frontend" span but the last is ParseAST's. IR generation that ran
    // inside one of them is billed as its child, so the parse row's self time
    // is parse + sema alone.
    if fe.size() > 1 {
        var unsafe *r_fe = TimeReport::region_under(
            at,
            cxx::std::string("Emission"),
        )

        var r_fir: unsafe *TimeReport::Record = &null
        for var i: usize = 0; i + 1 < fe.size(); ++i {
            const w = fe[i]
            bill(c, r_fe, w)
            bill_irgen(c, fns, r_fe, &r_fir, w.ts, w.ts + w.dur)
        }
    }

    if !fe.empty() {
        bill(
            c,
            TimeReport::region_under(at, cxx::std::string("SSALowering")),
            fe.back(),
        )
    }

    bill_all(c, at, kairo::sref("Optimize"), opt, tot_opt, last_end)
    bill_all(c, at, kairo::sref("MachineCode"), mc, tot_mc, last_end)

    // After clang's last span: EndSourceFile freeing Sema and the AST.
    if harvest_ns > at_ns(c, last_end) {
        TimeReport::record_span(
            TimeReport::region_under(at, cxx::std::string("TUTeardown")),
            at_ns(c, last_end),
            harvest_ns - at_ns(c, last_end),
        )
    }

    // This harvest: write, cleanup, scan. Measurement, not compilation.
    var unsafe *r_h = TimeReport::region_under(
        at,
        cxx::std::string("ClangTrace"),
    )

    TimeReport::mark_idle(r_h)
    const done_ns: u64 = TimeReport::clock_ns()
    TimeReport::record_span(r_h, harvest_ns, done_ns - harvest_ns)
}
