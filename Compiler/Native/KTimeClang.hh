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
///   public way out is timeTraceProfilerWrite. Parsing it back costs a few
///   hundred microseconds per TU, and only under --time-passes.
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
#include <vector>

#include <llvm/ADT/SmallString.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/TimeProfiler.h>
#include <llvm/Support/raw_ostream.h>

namespace kairo {

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
    // -O0 a small TU's whole optimizer run is well under any useful one.
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

    llvm::Expected<llvm::json::Value> doc = llvm::json::parse(buf.str());
    if (!doc) {
        llvm::consumeError(doc.takeError());
        return;
    }
    const llvm::json::Object *root   = doc->getAsObject();
    const llvm::json::Array  *events = root ? root->getArray("traceEvents") : nullptr;
    if (events == nullptr) { return; }

    struct Span {
        uint64_t ts;
        uint64_t dur;
    };
    libcxx::vector<Span> fe, fn, opt, mc;

    // Exact names only: the profiler also writes a "Total <name>" summary per
    // name at ts 0, which would double every row.
    for (const llvm::json::Value &v : *events) {
        const llvm::json::Object *o = v.getAsObject();
        if (o == nullptr) { continue; }
        auto ph = o->getString("ph");
        if (!ph || *ph != "X") { continue; }
        auto name = o->getString("name");
        auto ts   = o->getInteger("ts");
        auto dur  = o->getInteger("dur");
        if (!name || !ts || !dur || *ts < 0 || *dur < 0) { continue; }

        Span s{uint64_t(*ts), uint64_t(*dur)};
        if      (*name == "Emission")         { fe.push_back(s);  }
        else if (*name == "CodeGen Function") { fn.push_back(s);  }
        else if (*name == "Optimizer")        { opt.push_back(s); }
        else if (*name == "CodeGenPasses")    { mc.push_back(s);  }
    }

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
