// `Sink(args...)` over a pack is checked against the constructors per
// instance: a pack of three arguments matches neither Sink constructor and
// the instance is rejected, with no internal error.

class Sink {
    pub var total: i32
    pub fn Sink(self, a: i32, b: i32) { self.total = a + b }
    pub fn Sink(self, a: i32) { self.total = a * 10 }
}
fn <...A> make(...args: A) -> Sink { return Sink(args...) }

fn main() -> i32 {
    var s = make(1, 2, 3)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --implicit-check-not='I003E' --implicit-check-not='I011W'
// CHECK: ctor_from_pack_reject.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: no matching constructor for initialization of '::ctor_from_pack_reject::Sink'
