// `x in y` needs an `op in` on y's type that takes x: a record without one
// is SC066E, naming the operand type.

class Plain {
    var flag: bool = false
    fn Plain(self) { }
}

fn main() -> i32 {
    var p = Plain()
    return (1 in p) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: in_without_op_in.k:11:13: error [SC066E]: 'in' needs an 'op in' on 'Plain' taking a 'i32'
