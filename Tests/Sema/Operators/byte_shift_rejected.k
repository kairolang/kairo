// The count of a `byte` shift is an integer; a float or a bool is not.

fn main() -> i32 {
    var a: byte = 3 as byte
    var b = a << 1.5
    var c = 1 << a
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: byte_shift_rejected.k:5:13: error [SC067E]: shift operands must be integers
// CHECK: byte_shift_rejected.k:6:13: error [SC067E]: shift operands must be integers
