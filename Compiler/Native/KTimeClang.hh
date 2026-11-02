/// --- The Kairo Project -------------------------- Native/KTimeClang.hh --- ///
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
///       Frontend      ParseAST's "Frontend": parse + sema of the C++
///         IRGen       "CodeGen Function" emitted decl-at-a-time while parsing
///       IRGen         BackendConsumer's "Frontend": deferred decls, finalize
///       Optimize      "Optimizer" (the new-PM module pipeline)
///       MachineCode   "CodeGenPasses" (ISel through object emission)
///
///   Clang names two different scopes "Frontend". The one opened by
///   BackendConsumer::HandleTranslationUnit is always the LAST to start,
///   since ParseAST calls HandleTranslationUnit after its own scope closes;
///   that ordering is what tells them apart.
///
///   WHY THE JSON. TimeTraceProfiler keeps its entries private; the only
///   public way out is timeTraceProfilerWrite. It is read back by a scanner
///   (detail::scan_trace), not llvm::json::parse: the big TU's document has
///   ~13k events, and building its DOM was ~70 ms of --time-passes' cost.
///
///   THREADING. The profiler instance is thread_local, so only the thread
///   running ExecuteAction records; HeaderSet builds on pool workers see no
///   instance and their scopes stay free. If something else already armed a
///   profiler on this thread, begin() leaves it alone and nothing is harvested.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_TOOLCHAIN_CORE_KTIMECLANG_HH__
#define __KAIRO_TOOLCHAIN_CORE_KTIMECLANG_HH__

#include "KTimeReport.hh"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
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

/// Arms LLVM's profiler on this thread. Call immediately before
/// ExecuteAction, while the region the spans belong under is open.
inline KClangTimeCapture ktime_clang_begin() {
    KClangTimeCapture c;
    if (!TimeReport::enabled() || llvm::timeTraceProfilerEnabled()) { return c; }

    // Granularity 0: a scope shorter than the threshold is dropped, and at
    // -O0 a small TU's whole optimizer run is well under any useful one --
    // and so is most "CodeGen Function", which IRGen's row sums. A nonzero
    // one also breaks telling the two "Frontend" scopes apart (end(), by
    // order), since either may be the one dropped.
    llvm::timeTraceProfilerInitialize(0, "kairo");

    // The profiler's `ts` is microseconds since its own construction, on the
    // same steady clock TimeReport stamps with. Taking the anchor right after
    // lines the two up to within the cost of this call.
    c.anchor_ns = TimeReport::clock_ns();
    c.armed     = true;
    return c;
}

/// Disarms the profiler and bills what clang measured under the region
/// active on this thread. Call right after ExecuteAction, before that region
/// closes.
inline void ktime_clang_end(const KClangTimeCapture &c) {
    if (!c.armed) { return; }

    llvm::SmallString<0> buf;
    {
        llvm::raw_svector_ostream os(buf);
        llvm::timeTraceProfilerWrite(os);
    }
    llvm::timeTraceProfilerCleanup();

    struct Span {
        uint64_t ts;
        uint64_t dur;
    };
    libcxx::vector<Span> fe, fn, opt, mc;

    // Exact names only: the profiler also writes a "Total <name>" summary per
    // name at ts 0, which would double every row.
    detail::scan_trace(buf.str(), [&](llvm::StringRef name, int64_t ts, int64_t dur) {
        if (ts < 0 || dur < 0) { return; }
        Span s{uint64_t(ts), uint64_t(dur)};
        if      (name == "Frontend" || name == "Emission") { fe.push_back(s);  }
        else if (name == "CodeGen Function")               { fn.push_back(s);  }
        else if (name == "Optimizer")                      { opt.push_back(s); }
        else if (name == "CodeGenPasses")                  { mc.push_back(s);  }
    });

    auto by_ts = [](const Span &a, const Span &b) { return a.ts < b.ts; };
    libcxx::sort(fe.begin(), fe.end(), by_ts);
    libcxx::sort(fn.begin(), fn.end(), by_ts);

    TimeReport::Record *at = TimeReport::current();
    auto at_ns = [&](uint64_t us) { return c.anchor_ns + us * 1000ull; };
    auto bill  = [&](TimeReport::Record *rec, const Span &s) {
        TimeReport::record_span(rec, at_ns(s.ts), s.dur * 1000ull);
    };

    // Every "Emission" but the last is ParseAST's. IR generation that ran
    // inside one of them is billed as its child, so the parse row's self time
    // is parse + sema alone.
    if (fe.size() > 1) {
        TimeReport::Record *r_fe  = TimeReport::region_under(at, "Emission");
        TimeReport::Record *r_fir = nullptr;
        uint64_t            last  = 0;   // end of the last billed function: skip nested ones
        for (size_t i = 0; i + 1 < fe.size(); ++i) {
            const Span &w = fe[i];
            bill(r_fe, w);
            for (const Span &f : fn) {
                if (f.ts < w.ts || (f.ts + f.dur) > (w.ts + w.dur)) { continue; }
                if (f.ts < last) { continue; }
                if (r_fir == nullptr) { r_fir = TimeReport::region_under(r_fe, "SSALowering"); }
                bill(r_fir, f);
                last = f.ts + f.dur;
            }
        }
    }
    if (!fe.empty()) { bill(TimeReport::region_under(at, "SSALowering"), fe.back()); }
    for (const Span &s : opt) { bill(TimeReport::region_under(at, "Optimize"), s); }
    for (const Span &s : mc)  { bill(TimeReport::region_under(at, "MachineCode"), s); }
}

} // namespace kairo

#endif // __KAIRO_TOOLCHAIN_CORE_KTIMECLANG_HH__
