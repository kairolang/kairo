/// --- The Kairo Project ------------------------- Native/KTimeClang.hh --- ///
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
///                     (their "CodeGen Function" is a child IRGen row)
///       Frontend      ParseAST's "Frontend": parse + sema of the C++
///         IRGen       "CodeGen Function" emitted decl-at-a-time while parsing
///       IRGen         BackendConsumer's "Frontend": deferred decls, finalize
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
///   other's. At granularity 0 a TU averaged ~86k events (every pass on
///   every function; 27 M over the self-build), and a sampled --time-passes
///   build had 81% of its codegen workers waiting on that lock: the "idle"
///   gaps between TUs in the trace were this harvest. At 50 us the build
///   writes 43x fewer events and the IRGen-inside-parse row keeps 99.5% of
///   its time (the dropped functions stay in the parse row's self time).
///   No "Frontend" scope of the self-build is under 500 us. A dropped
///   "Optimizer" / "CodeGenPasses" / "ReadAST" is not lost: the profiler
///   keeps an exact "Total <name>" for every name whatever the threshold,
///   and the difference is billed as one span.
///
///   WHY THE JSON. TimeTraceProfiler keeps its entries private; the only
///   public way out is timeTraceProfilerWrite. It is read back by a scanner
///   (detail::scan_trace), not llvm::json::parse.
///
///   THREADING. The profiler instance is thread_local, so only the thread
///   running ExecuteAction records; HeaderSet builds on pool workers see no
///   instance and their scopes stay free. If something else already armed a
///   profiler on this thread, begin() leaves it alone and nothing is harvested.
///   The fill marks (ktime_clang_mark_fill_*) are thread_local too: the fill
///   runs on the thread that called ExecuteAction.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_TOOLCHAIN_CORE_KTIMECLANG_HH__
#define __KAIRO_TOOLCHAIN_CORE_KTIMECLANG_HH__

#include "KTimeReport.hh"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <atomic>
#include <cstdio>
#include <string>
#include <vector>

#include <llvm/ADT/SmallString.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/TimeProfiler.h>
#include <llvm/Support/raw_ostream.h>

namespace kairo {

namespace detail {

/// \brief calls \p f(name, ts, dur) for every complete ("ph":"X") event in
///        a timeTraceProfilerWrite() document.
///
/// \details A scanner, not llvm::json::parse: the document of one big TU at
///          granularity 0 holds ~13k events (every pass on every function),
///          and building the DOM for it cost ~70 ms where reading the four
///          names that matter costs ~1 ms -- most of what --time-passes
///          added to a build. It only needs what the writer emits: one array
///          of flat event objects, whose "args" (an object) is skipped. Keys
///          are matched in any order. Malformed input stops the scan; the
///          rows then miss what came after, nothing worse.
template <typename F>
inline void scan_trace(llvm::StringRef doc, F &&f) {
    const char *p = doc.data();
    const char *e = p + doc.size();
    auto ws  = [&] { while (p < e && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t' || *p == ',')) { ++p; } };
    // A string at p (p on its opening quote); its raw bytes, escapes kept.
    auto str = [&](llvm::StringRef &out) -> bool {
        if (p >= e || *p != '"') { return false; }
        const char *b = ++p;
        while (p < e && *p != '"') { p += (*p == '\\') ? 2 : 1; }
        if (p >= e) { return false; }
        out = llvm::StringRef(b, size_t(p - b));
        ++p;
        return true;
    };
    // Any value that is not read: a string, number, literal, or a nested
    // object / array (balanced, strings honoured).
    auto skip = [&]() -> bool {
        if (p >= e) { return false; }
        if (*p == '"') { llvm::StringRef s; return str(s); }
        if (*p == '{' || *p == '[') {
            int depth = 0;
            while (p < e) {
                char c = *p;
                if (c == '"') { llvm::StringRef s; if (!str(s)) { return false; } continue; }
                if (c == '{' || c == '[') { ++depth; }
                if (c == '}' || c == ']') { if (--depth == 0) { ++p; return true; } }
                ++p;
            }
            return false;
        }
        while (p < e && *p != ',' && *p != '}' && *p != ']') { ++p; }
        return true;
    };
    auto num = [&](int64_t &out) -> bool {
        bool neg = (p < e && *p == '-');
        if (neg) { ++p; }
        if (p >= e || *p < '0' || *p > '9') { return skip(); }
        int64_t v = 0;
        while (p < e && *p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); ++p; }
        if (p < e && (*p == '.' || *p == 'e' || *p == 'E')) { skip(); }
        out = neg ? -v : v;
        return true;
    };

    size_t at = doc.find("\"traceEvents\"");
    if (at == llvm::StringRef::npos) { return; }
    p += at + 13;
    while (p < e && *p != '[') { ++p; }
    if (p >= e) { return; }
    ++p;
    for (;;) {
        ws();
        if (p >= e || *p == ']') { return; }
        if (*p != '{') { return; }
        ++p;
        llvm::StringRef name, ph;
        int64_t ts = -1, dur = -1;
        for (;;) {
            ws();
            if (p >= e) { return; }
            if (*p == '}') { ++p; break; }
            llvm::StringRef key;
            if (!str(key)) { return; }
            ws();
            if (p >= e || *p != ':') { return; }
            ++p;
            ws();
            bool ok = true;
            if      (key == "name") { ok = str(name); }
            else if (key == "ph")   { ok = str(ph); }
            else if (key == "ts")   { ok = num(ts); }
            else if (key == "dur")  { ok = num(dur); }
            else                    { ok = skip(); }
            if (!ok) { return; }
        }
        if (ph == "X") { f(name, ts, dur); }
    }
}

} // namespace detail

/// What begin() hands end(). Plain data so the Kairo side can hold it in a
/// `var` across the ExecuteAction call.
struct KClangTimeCapture {
    uint64_t anchor_ns = 0;      ///< TimeReport clock at profiler start
    bool     armed     = false;  ///< false: timing off, or a profiler was already live
};

/// Below this a clang scope keeps only its "Total" (see GRANULARITY above).
constexpr unsigned kClangTraceGranularityUs = 50;

namespace detail {

/// When the Kairo fill began and ended on this thread, for the TU whose
/// capture is armed here. Set from KairoInject (CodegenAction.k), read and
/// cleared by ktime_clang_end.
struct KClangFillMarks {
    uint64_t begin_ns = 0;
    uint64_t end_ns   = 0;
    bool     armed    = false;
};

inline KClangFillMarks &clang_fill_marks() {
    static thread_local KClangFillMarks m;
    return m;
}

} // namespace detail

/// Arms LLVM's profiler on this thread. Call immediately before
/// ExecuteAction, while the region the spans belong under is open.
inline KClangTimeCapture ktime_clang_begin() {
    KClangTimeCapture c;
    if (!TimeReport::enabled() || llvm::timeTraceProfilerEnabled()) { return c; }

    llvm::timeTraceProfilerInitialize(kClangTraceGranularityUs, "kairo");

    // The profiler's `ts` is microseconds since its own construction, on the
    // same steady clock TimeReport stamps with. Taking the anchor right after
    // lines the two up to within the cost of this call.
    c.anchor_ns = TimeReport::clock_ns();
    c.armed     = true;
    detail::clang_fill_marks() = detail::KClangFillMarks{0, 0, true};
    return c;
}

/// The Kairo fill of the armed TU starts (BeginSourceFileAction). No-op
/// unless a capture is armed on this thread.
inline void ktime_clang_mark_fill_begin() {
    detail::KClangFillMarks &m = detail::clang_fill_marks();
    if (m.armed) { m.begin_ns = TimeReport::clock_ns(); }
}

/// The Kairo fill of the armed TU is done: its stream is in the preprocessor.
inline void ktime_clang_mark_fill_end() {
    detail::KClangFillMarks &m = detail::clang_fill_marks();
    if (m.armed) { m.end_ns = TimeReport::clock_ns(); }
}

/// Disarms the profiler and bills what clang measured under the region
/// active on this thread. Call right after ExecuteAction, before that region
/// closes.
inline void ktime_clang_end(const KClangTimeCapture &c) {
    if (!c.armed) { return; }
    const uint64_t harvest_ns = TimeReport::clock_ns();   // ExecuteAction has returned
    const detail::KClangFillMarks marks = detail::clang_fill_marks();
    detail::clang_fill_marks() = detail::KClangFillMarks{};

    llvm::SmallString<0> buf;
    {
        llvm::raw_svector_ostream os(buf);
        llvm::timeTraceProfilerWrite(os);
    }
    llvm::timeTraceProfilerCleanup();

    // KAIRO_CLANG_TRACE_DIR: keep each TU's raw clang trace (chrome JSON) as
    // <dir>/<n>.json, for finding what clang spends a TU's frontend on.
    if (const char *dir = ::std::getenv("KAIRO_CLANG_TRACE_DIR")) {
        static ::std::atomic<unsigned> n{0};
        ::std::string path = ::std::string(dir) + "/" + ::std::to_string(n.fetch_add(1)) + ".json";
        if (FILE *f = ::std::fopen(path.c_str(), "wb")) {
            ::std::fwrite(buf.data(), 1, buf.size(), f);
            ::std::fclose(f);
        }
    }

    struct Span {
        uint64_t ts;
        uint64_t dur;
    };
    libcxx::vector<Span> fe, fn, opt, mc, rd;
    uint64_t last_end = 0;                     // us: end of the last span clang kept
    uint64_t tot_opt = 0, tot_mc = 0;          // us: "Total <name>", every scope of the name

    // Exact names only: the profiler also writes a "Total <name>" summary per
    // name at ts 0, read here for what the granularity dropped.
    detail::scan_trace(buf.str(), [&](llvm::StringRef name, int64_t ts, int64_t dur) {
        if (ts < 0 || dur < 0) { return; }
        if (name.starts_with("Total ")) {
            llvm::StringRef base = name.drop_front(6);
            if      (base == "Optimizer")     { tot_opt = uint64_t(dur); }
            else if (base == "CodeGenPasses") { tot_mc  = uint64_t(dur); }
            return;
        }
        Span s{uint64_t(ts), uint64_t(dur)};
        if (s.ts + s.dur > last_end) { last_end = s.ts + s.dur; }
        if      (name == "Frontend" || name == "Emission") { fe.push_back(s);  }
        else if (name == "CodeGen Function")               { fn.push_back(s);  }
        else if (name == "Optimizer")                      { opt.push_back(s); }
        else if (name == "CodeGenPasses")                  { mc.push_back(s);  }
        else if (name == "ReadAST")                        { rd.push_back(s);  }
    });

    auto by_ts = [](const Span &a, const Span &b) { return a.ts < b.ts; };
    libcxx::sort(fe.begin(), fe.end(), by_ts);
    libcxx::sort(fn.begin(), fn.end(), by_ts);

    TimeReport::Record *at = TimeReport::current();
    auto at_ns = [&](uint64_t us) { return c.anchor_ns + us * 1000ull; };
    auto bill  = [&](TimeReport::Record *rec, const Span &s) {
        TimeReport::record_span(rec, at_ns(s.ts), s.dur * 1000ull);
    };
    // The outermost "CodeGen Function" spans inside [lo, hi) (us), each
    // billed to \p *r, created under \p parent on first use.
    auto bill_irgen = [&](TimeReport::Record *parent, TimeReport::Record *&r, uint64_t lo, uint64_t hi) {
        uint64_t last = 0;   // end of the last billed function: skip nested ones
        for (const Span &f : fn) {
            if (f.ts < lo || (f.ts + f.dur) > hi) { continue; }
            if (f.ts < last) { continue; }
            if (r == nullptr) { r = TimeReport::region_under(parent, "SSALowering"); }
            bill(r, f);
            last = f.ts + f.dur;
        }
    };

    // Clang's own setup before the fill: from the anchor (ExecuteAction's
    // start) to BeginSourceFileAction.
    if (marks.begin_ns > c.anchor_ns) {
        TimeReport::record_span(TimeReport::region_under(at, "TUSetup"), c.anchor_ns, marks.begin_ns - c.anchor_ns);
    }

    // From the fill's end to ParseAST: the PCH and everything built on it.
    if (marks.end_ns != 0 && !fe.empty() && at_ns(fe.front().ts) > marks.end_ns) {
        const uint64_t lo_ns = marks.end_ns;
        const uint64_t hi_ns = at_ns(fe.front().ts);
        TimeReport::Record *r_pch = TimeReport::region_under(at, "PCHLoad");
        TimeReport::record_span(r_pch, lo_ns, hi_ns - lo_ns);
        const uint64_t lo_us = (lo_ns - c.anchor_ns) / 1000ull;
        const uint64_t hi_us = fe.front().ts;
        TimeReport::Record *r_rd = nullptr;
        for (const Span &s : rd) {
            if (s.ts < lo_us || (s.ts + s.dur) > hi_us) { continue; }
            if (r_rd == nullptr) { r_rd = TimeReport::region_under(r_pch, "ReadAST"); }
            bill(r_rd, s);
        }
        TimeReport::Record *r_eager = nullptr;
        bill_irgen(r_pch, r_eager, lo_us, hi_us);
    }

    // Every "Emission" but the last is ParseAST's. IR generation that ran
    // inside one of them is billed as its child, so the parse row's self time
    // is parse + sema alone.
    if (fe.size() > 1) {
        TimeReport::Record *r_fe  = TimeReport::region_under(at, "Emission");
        TimeReport::Record *r_fir = nullptr;
        for (size_t i = 0; i + 1 < fe.size(); ++i) {
            const Span &w = fe[i];
            bill(r_fe, w);
            bill_irgen(r_fe, r_fir, w.ts, w.ts + w.dur);
        }
    }
    if (!fe.empty()) { bill(TimeReport::region_under(at, "SSALowering"), fe.back()); }

    // Kept spans, then what the granularity dropped (the "Total" exceeds
    // what was kept) as one span after the last one kept.
    auto bill_all = [&](const char *row, const libcxx::vector<Span> &v, uint64_t total) {
        uint64_t kept = 0, end = last_end;
        TimeReport::Record *r = nullptr;
        for (const Span &s : v) {
            if (r == nullptr) { r = TimeReport::region_under(at, row); }
            bill(r, s);
            kept += s.dur;
            end = s.ts + s.dur;
        }
        if (total > kept) {
            if (r == nullptr) { r = TimeReport::region_under(at, row); }
            bill(r, Span{end, total - kept});
        }
    };
    bill_all("Optimize", opt, tot_opt);
    bill_all("MachineCode", mc, tot_mc);

    // After clang's last span: EndSourceFile freeing Sema and the AST.
    if (harvest_ns > at_ns(last_end)) {
        TimeReport::record_span(TimeReport::region_under(at, "TUTeardown"), at_ns(last_end), harvest_ns - at_ns(last_end));
    }

    // This harvest: write, cleanup, scan. Measurement, not compilation.
    TimeReport::Record *r_h = TimeReport::region_under(at, "ClangTrace");
    TimeReport::mark_idle(r_h);
    const uint64_t done_ns = TimeReport::clock_ns();
    TimeReport::record_span(r_h, harvest_ns, done_ns - harvest_ns);
}

} // namespace kairo

#endif // __KAIRO_TOOLCHAIN_CORE_KTIMECLANG_HH__
