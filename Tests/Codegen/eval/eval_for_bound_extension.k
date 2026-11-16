// An `eval for` over a range keeps its bounds in the loop statement after
// iteration lowering, and the later lowering passes reach them like any
// other child: an extension call in a bound is rewritten to a free call.
extend i32 { eval fn twice(const self) -> i32 { return self * 2 } }
eval N: i32 = 2
fn b() -> i32 {
    var s = 0
    eval for i in 0..N.twice() { s += i }
    return s
}
fn main() -> i32 {
    if b() != 6 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
