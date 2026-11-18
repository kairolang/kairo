// A name written as a binder's type that names no type is an error, on a loop
// binder and on a destructuring binder.

fn main() -> i32 {
    var xs = [1, 2, 3]
    for x: Undefined in xs { }
    var t = (1, 2)
    var (a: Nope, b) = t
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: binder_written_type_unknown.k:6:12: error [R021E]: unknown type name 'Undefined'
// CHECK: binder_written_type_unknown.k:8:13: error [R021E]: unknown type name 'Nope'
