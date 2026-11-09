// The panicking operators PanicLowering does not lower yet (lowers
// the rest, Tests/Codegen/panic/operators.k): an `op as`, which C++ spells
// as a conversion function returning its target type, and a place `op []`
// returning `*T`, which C++ declares returning `T&`. Each call is SC116E;
// an ordinary panicking operator beside them is not.
struct Bad {}

struct Cell {
    var v: i32
    fn op as (const self) panic(Bad) -> i32 {
        if self.v < 0 { panic Bad {} }
        return self.v
    }
    fn op [] (self, i: i32) panic(Bad) -> *i32 {
        if i != 0 { panic Bad {} }
        return &self.v
    }
    fn op + (const self, o: Cell) panic(Bad) -> Cell { return Cell { v: self.v + o.v } }
}

fn main() -> i32 {
    var c = Cell { v: 1 }
    var a = try (c as i32) catch e: Bad => 0
    var b = try c[0] catch e: Bad => 0
    var d = try (c + c).v catch e: Bad => 0
    return a + b + d
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: operator_gates.k:23:18: error [SC116E]: a call of a panicking 'op as' is not yet supported
// CHECK: operator_gates.k:24:17: error [SC116E]: a call of a panicking place operator ('op []' returning a pointer) is not yet supported
