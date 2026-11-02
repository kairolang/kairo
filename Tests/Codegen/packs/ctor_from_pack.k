// P238: a constructor called with a pack expansion inside a generic body,
// `Sink(args...)`, is typed as its record even though which constructor
// wins is the instance's question (clang picks it from the emitted
// `Sink(args...)`). It reached codegen untyped and ICEd (I011W "untyped
// constructor call"). Asserted: it compiles, both a two-argument and a
// one-argument constructor are reached through the same forwarding
// function, and the values arrive.

class Sink {
    pub var total: i32
    pub fn Sink(self, a: i32, b: i32) { self.total = a + b }
    pub fn Sink(self, a: i32) { self.total = a * 10 }
}
fn <...A> make(...args: A) -> Sink { return Sink(args...) }

fn main() -> i32 {
    var s = make(1, 2)
    if s.total != 3 { return 1 }
    var t = make(4)
    if t.total != 40 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
