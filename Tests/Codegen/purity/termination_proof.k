// `[[gnu::const]]` and `[[gnu::pure]]` are `willreturn` to clang: an unused
// or foldable call is deleted, a loop in it that never exits included. The
// attribute is spelled only on a function whose termination is proven: no
// `while`, `loop`, C-style `for` or label/jump in its body (a `for` over a
// range, a fixed array or a slice is bounded), no call cycle through it, and
// every callee proven too. The Kairo-level promise is not changed: a written
// `const` function with an unbounded loop still compiles, without the C++
// attribute.

fn twice(x: i32) const -> i32 { return x * 2 }
fn sum_to(n: i32) -> i32 {
    var s = 0
    for i in 0..n { s += i }
    return s
}
fn sum_arr(n: i32) -> i32 {
    var a: [i32; 4] = [n, n + 1, n + 2, n + 3]
    var s = 0
    for x in a { s += x }
    return s
}
fn uses_sum(n: i32) -> i32 { return sum_to(n) + twice(n) }

fn spin(n: i32) -> i32 {
    var i = 0
    while i != n { i += 2 }
    return i
}
fn spin_loop(n: i32) -> i32 {
    var i = n
    loop {
        if i == 0 { break }
        i -= 2
    }
    return i
}
fn c_for(n: i32) -> i32 {
    var s = 0
    for var i = 0; i < n; ++i { s += i }
    return s
}
fn calls_spin(n: i32) -> i32 { return spin(n) + 1 }
fn rec(n: i32) -> i32 { return rec(n + 1) }
fn even(n: u32) -> bool { if n == 0 { return true }; return odd(n - 1) }
fn odd(n: u32) -> bool { if n == 0 { return false }; return even(n - 1) }

fn w_ok(x: i32) const -> i32 { return twice(x) + 1 }
fn w_spin(n: i32) const -> i32 {
    var i = 0
    while i != n { i += 2 }
    return i
}
fn w_calls(n: i32) const -> i32 { return w_spin(n) }

fn main() -> i32 {
    if sum_to(5) != 10 { return 1 }
    if sum_arr(1) != 10 { return 2 }
    if uses_sum(4) != 14 { return 3 }
    if spin(4) != 4 || spin_loop(6) != 0 || c_for(4) != 6 { return 4 }
    if calls_spin(2) != 3 { return 5 }
    if !even(10) || odd(10) { return 6 }
    if w_ok(3) != 7 || w_calls(2) != 2 { return 7 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=YES
// YES-DAG: __attribute{{(__)?}}((const)) signed int twice(
// YES-DAG: __attribute{{(__)?}}((const)) signed int sum_to(
// YES-DAG: __attribute{{(__)?}}((const)) signed int sum_arr(
// YES-DAG: __attribute{{(__)?}}((const)) signed int uses_sum(
// YES-DAG: __attribute{{(__)?}}((const)) signed int w_ok(

// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NO
// NO-NOT: (({{const|pure}})) {{signed int|bool}} {{spin|spin_loop|c_for|calls_spin|rec|even|odd|w_spin|w_calls}}(

// The written promise is held to the same proof without -finfer-purity.
// RUN: { %kairo %s -fno-infer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=OFF
// OFF-DAG: __attribute{{(__)?}}((const)) signed int w_ok(
// OFF-NOT: (({{const|pure}})) signed int {{w_spin|w_calls}}(

// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -finfer-purity -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe
// RUN: %kairo %s -finfer-purity -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe
