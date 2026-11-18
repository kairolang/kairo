// A tuple literal converts element by element into a tuple type with
// nullable elements, and only where each element converts on its own: a
// `null` for an element that is not nullable, or a value of another type,
// is rejected.

fn main() -> i32 {
    var a: (i32?, i32) = (5, null)
    var b: (i32?, i32) = ("a", 1)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: tuple_nullable_element_conversion.k:7:30: error [SC076E]: cannot infer the type of 'null' here; annotate the target with a nullable type
// CHECK: tuple_nullable_element_conversion.k:8:26: error [SC028E]: cannot convert '(string, i32)' to '(i32?, i32)'
// CHECK: tuple_nullable_element_conversion.k:8:27: error [SC028E]: cannot convert 'string' to 'i32?'
