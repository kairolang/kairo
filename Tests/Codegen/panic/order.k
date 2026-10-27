// A panicking call's arguments run left to right, and a panic stops them
// there (PANIC.md §4.5): SequenceLowering orders a call whose result is a
// panic result like any call, though it is a record (it is always movable),
// and an argument that panics leaves before the ones after it run.
struct E { var c: i32 }
var seq: i32 = 0
fn step(d: i32) -> i32 { seq = seq * 10 + d; return d }
fn pstep(d: i32) panic(E) -> i32 { seq = seq * 10 + d; if d == 9 { panic E { c: 1 } } return d }
fn sum(a: i32, b: i32, c: i32) panic(E) -> i32 { return a + b + c }
fn main() -> i32 {
    var v = try sum(step(1), pstep(2), step(3)) catch => 0
    if (seq != 123) || (v != 6) { return 1 }
    seq = 0
    var w = try sum(step(1), pstep(9), step(3)) catch => 50
    if (seq != 19) || (w != 50) { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
