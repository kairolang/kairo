// XFAIL: *
// A constructor called with a pack expansion inside a generic body,
// `Sink(args...)`, reaches codegen untyped: I011W "EmitIR: untyped
// constructor call; ExprTyper gate failure (CallExpr)". It predates P225
// (the forwarding change); see TICKETS.TXT. Flip to a plain run when it
// types.

class Sink {
    pub var total: i32
    pub fn Sink(self, a: i32, b: i32) { self.total = a + b }
}
fn <...A> make(...args: A) -> Sink { return Sink(args...) }

fn main() -> i32 {
    var s = make(1, 2)
    return s.total - 3
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
