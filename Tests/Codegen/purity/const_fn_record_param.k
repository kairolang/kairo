// A const function (`[[gnu::const]]`, LLVM memory(none)) must never
// read memory its caller can change. ParamPassInference used to pass a
// never-mutated COPY record parameter as `const T&`, so `first` read `b`
// through a reference while clang believed it read nothing, and merged
// the second call into the first across the store `b.a = 5` (2 at -O2,
// 6 at -O0). A const function keeps its by-value parameter: C++ passes a
// non-trivial record through a fresh caller copy, and clang weakens the
// promise to "reads its argument copies" for it.

class Big {
    var a: i32 = 1
    var s: string = "x"
}

fn first(p: Big) const -> i32 { return p.a; }

fn main() -> i32 {
    var b = Big()
    var r = first(b)
    b.a = 5
    return r + first(b) - 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: SC224W

// The parameter stays by value in the C++ signature.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __attribute{{(__)?}}((const)) signed int first({{[^&]*}}Big p)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
