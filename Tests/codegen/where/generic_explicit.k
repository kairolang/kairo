// where/generic_explicit.k -- exit 0
// A generic `where` group (where.mdx) whose parameters C++ cannot deduce
// from the forwarded arguments: a type parameter no parameter's type
// mentions, and a value parameter (generics.mdx, `eval N`). The dispatcher
// writes its own parameters as each candidate's arguments
// (`__kairo_where_width_0<T>(n)`), so nothing is left to deduce.

// Undeduced: the caller names T.
fn <T> width(n: i32) -> usize where n > 0 { return sizeof T }
fn <T> width(n: i32) -> usize { return 0 }

// A value parameter given explicitly, read by the guard.
fn <eval N: i32> above(x: i32) -> i32 where x > N { return 1 }
fn <eval N: i32> above(x: i32) -> i32 { return 0 }

// A value parameter deduced from an array's length.
fn <eval N: usize> big(const a: [i32; N]) -> i32 where N > 2 { return a[N - 1] }
fn <eval N: usize> big(const a: [i32; N]) -> i32 { return a[0] }

fn main() -> i32 {
    var r = 0
    if width<i64>(7) != 8      { r += 1 }
    if width<i32>(-3) != 0     { r += 2 }
    if above<5>(9) != 1        { r += 4 }
    if above<5>(2) != 0        { r += 8 }
    var a3 = [10, 20, 30]
    var a2 = [40, 50]
    if big(a3) != 30           { r += 16 }
    if big(a2) != 40           { r += 32 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: return{{.*}}::__kairo_where_width_0<T>(n);
// CXX: return{{.*}}::__kairo_where_width_1<T>(n);
// CXX: return{{.*}}::__kairo_where_above_0<N>(x);
// CXX: return{{.*}}::__kairo_where_big_1<N>(a);
// CXX-NOT: {{(error|warning) @}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
