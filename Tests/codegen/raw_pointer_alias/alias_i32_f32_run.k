// Writes through an `unsafe *i32` and an `unsafe *f32` over the same
// storage are not reordered by type-based alias analysis: the read through
// the `unsafe *i32` sees the float's bits at every optimization level.
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe
// RUN: %t.exe | %FileCheck %s
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: result=1073741824 wide=4611686018427387904 back=7

import std::io

@no_inline
fn f(a: unsafe *i32, b: unsafe *f32) -> i32 {
    *a = 1
    *b = 2.0f32
    return *a
}

@no_inline
fn g(a: unsafe *u64, b: unsafe *f64) -> u64 {
    *a = 1
    *b = 2.0
    return *a
}

@no_inline
fn h(a: unsafe *const i32, b: unsafe *i32) -> i32 {
    *b = 7
    return *a
}

fn main() -> i32 {
    var x: i32 = 0
    var y: u64 = 0
    unsafe {
        var pi: unsafe *i32 = &x as unsafe *i32
        var pf: unsafe *f32 = &x as unsafe *f32
        var pu: unsafe *u64 = &y as unsafe *u64
        var pd: unsafe *f64 = &y as unsafe *f64
        var c = f(pi, pf)
        var w = g(pu, pd)
        io::println(f"result={c} wide={w} back={h(pi as unsafe *const i32, pi)}")
    }

    return 0
}
