// A panicking interface requirement whose result names `Self`: its panic
// result is spelled outside the witness (every conformer returns it), where
// `Self` has no C++ type, and codegen stopped on the interface with an
// internal error (I003E) -- for the declaration alone, a conformer, a call
// through a bound in method form (`a.add(a)`), and since that case lowers
// panicking operators, the operator form (`a + a`) too. It is SC116E at
// the requirement, with a note at the result. A requirement whose result
// is a concrete type works, operator form included
// (Tests/Codegen/panic/operators.k, `Gauge`).
struct E { var c: i32 }

interface Add {
    fn op + (const self, o: Self) panic(E) -> Self
}
interface Grow {
    fn add(const self, o: Self) panic(E) -> Self
}
interface Measure {
    fn op + (const self, o: i32) panic(E) -> i32
}

class N impl Add, Grow {
    var v: i32
    fn N(self, v: i32) { self.v = v }
    fn op + (const self, o: N) panic(E) -> N { return N(self.v + o.v) }
    fn add(const self, o: N) panic(E) -> N { return N(self.v + o.v) }
}

fn <T impl Add> twice(a: T) panic -> T { return a + a }
fn <T impl Grow> grow(a: T) panic -> T { return a.add(a) }
fn <T impl Measure> plus_one(a: T) panic -> i32 { return a + 1 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: requirement_self.k:13:35: error [SC116E]: a panicking interface requirement whose result names 'Self' ('op +') is not yet supported
// CHECK-NEXT: requirement_self.k:13:47: note [SC116N]: its result names 'Self' here
// CHECK: requirement_self.k:16:33: error [SC116E]: a panicking interface requirement whose result names 'Self' ('add') is not yet supported
// CHECK-NEXT: requirement_self.k:16:45: note [SC116N]: its result names 'Self' here
