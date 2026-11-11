// A bare primitive type name where a value is required. N leaves
// `u32` unbound on purpose (the head of `u32(x)`, the operand of
// `typeof T == u32`), so it never reached the type-expression side table and
// every value consumer passed it on as "unknown" with no error at all.
// It is SC094E like a record's name, with no fix-it: a builtin has no
// obvious edit (a record's name gets `()`).

fn main() -> i32 {
    var x: u32 = 3
    if x == u32 {
        return 1
    }

    var b = x != i64
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: primitive_type_as_value.k:10:13: error [SC094E]: 'u32' is a type, not a value
// CHECK-NOT: fix-it
// CHECK: primitive_type_as_value.k:14:18: error [SC094E]: 'i64' is a type, not a value
// CHECK-NOT: error
