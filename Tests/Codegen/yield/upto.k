fn upto(n: i32) -> yield i32 {
    for var i: i32 = 0; i < n; ++i {
        yield i
    }
}

fn main() -> i32 {
    var s: i32 = 0
    var g = upto(10)
    while g.next() { s += *g.current() }
    return s
}

// --- lit wiring -----------------------------------------------------------
// End to end: a generator compiles, links and runs (0 + 1 + ... + 9 == 45).
// Guards today's fixes together -- member `using` aliases (promise_type),
// `@no_unwind` -> noexcept, `co_yield`, and template bodies visible in the
// TU that instantiates them (YieldPromise<int>, Suspend::await_suspend<H>,
// which clang instantiates and Kairo never names).
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The preamble defines YieldPromise before Yield, so these two are unordered.
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: using promise_type =
// CXX-DAG: final_suspend() noexcept;

// Bodies are only in the IR, not the preamble.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: co_yield(i);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 45
