// A member whose `requires` clause the instance does not satisfy is not a
// member of that instance: building the instance is fine, calling the member
// is SC153E with a note naming the bound that fails, and an unconstrained
// member of the same instance is callable.

interface Shape { fn area(const self) -> i32 }
fn <U> sized(x: U) -> i32 requires U impl Shape { return x.area() }

struct Four { pub var a: i32 }

class <T> Holder {
    pub var v: T
    pub fn Holder(self, v: T) { self.v = v }
    pub fn total(const self) -> i32 requires T impl Shape {
        return sized<T>(self.v)
    }
    pub fn size(const self) -> usize { return sizeof T }
}

fn main() -> i32 {
    var f = Holder<Four>(Four { a: 1 })
    var n = f.size()
    return f.total()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: member_requires_not_met_call.k:23:12: error [SC153E]: 'total' cannot be called on 'Holder<Four>': its 'requires' clause does not hold
// CHECK: note [SC153N]: 'Four' does not conform to 'Shape'
