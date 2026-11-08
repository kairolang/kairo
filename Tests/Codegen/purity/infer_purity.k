// -finfer-purity: functions that keep the const / @pure promise without
// writing it get `[[gnu::const]]` / `[[gnu::pure]]` (FnPurityCheck::infer,
// a greatest fixpoint over the call graph, by the same rules the written
// promises are checked with). Off by default: no attribute is emitted.
// The run at -O2 is the miscompile check: an over-eager verdict lets clang
// merge or delete a call that matters.

var g: i32 = 7

class Big {
    var a: i32 = 1
    var s: string = "x"
}

fn sq(x: i32) -> i32 { return x * x }
fn sum_sq(a: i32, b: i32) -> i32 { return sq(a) + sq(b) }
fn reads_g(x: i32) -> i32 { return g + x }
fn uses_pure(x: i32) -> i32 { return reads_g(x) * 2 }
fn bumps(x: i32) -> i32 { g = x; return g }
fn calls_bumps(x: i32) -> i32 { return bumps(x) }
fn first(p: Big) -> i32 { return p.a }
fn even(n: u32) -> bool { if n == 0 { return true }; return odd(n - 1) }
fn odd(n: u32) -> bool { if n == 0 { return false }; return even(n - 1) }

fn main() -> i32 {
    var b = Big()
    var r = first(b)
    b.a = 5
    var t = r + first(b)
    var u = reads_g(1)
    var w = calls_bumps(10)
    var v = reads_g(1)
    if t != 6 { return 1 }
    if u != 8 { return 2 }
    if v != 11 || w != 10 { return 3 }
    if sum_sq(3, 4) != 25 { return 4 }
    if !even(10) { return 5 }
    if uses_pure(0) != 20 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=INF
// INF-DAG: __attribute{{(__)?}}((const)) signed int sq(
// INF-DAG: __attribute{{(__)?}}((const)) signed int sum_sq(
// INF-DAG: __attribute{{(__)?}}((pure)) signed int reads_g(
// INF-DAG: __attribute{{(__)?}}((pure)) signed int uses_pure(
// INF-DAG: __attribute{{(__)?}}((const)) bool even(
// INF-DAG: __attribute{{(__)?}}((const)) bool odd(
// INF-DAG: __attribute{{(__)?}}((const)) signed int first({{[^&]*}}Big p)

// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NEG
// NEG-NOT: (({{const|pure}})) signed int {{(calls_)?}}bumps(

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=OFF
// OFF-NOT: (({{const|pure}}))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -finfer-purity -O2 -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
