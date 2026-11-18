// A tuple literal converts element by element into a tuple with nullable
// elements: `(1, 1)` into `(i32?, i32)` is accepted, a `string` element
// for an `i32?` slot is SC028E (on the tuple and on the element).

fn main() -> i32 {
    var ok: (i32?, i32) = (1, 1)
    var bad: (i32?, i32) = ("a", 1)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: tuple_element_rejects.k:7:{{[0-9]+}}: error [SC028E]: cannot convert '(string, i32)' to '(i32?, i32)'
// CHECK: tuple_element_rejects.k:7:{{[0-9]+}}: error [SC028E]: cannot convert 'string' to 'i32?'
