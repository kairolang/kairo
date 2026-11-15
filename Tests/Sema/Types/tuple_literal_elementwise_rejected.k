// Only a tuple LITERAL converts element by element. A tuple value of
// another type converts to nothing, an element that does not convert
// keeps its error, and a literal of another arity is no match.

fn first(t: (*const i32, *i32)) -> i32 {
    return *t.0
}

fn main() -> i32 {
    var a = 1
    var b = 2
    var x = (&a, &b)
    var t: (*const i32, *i32) = x
    var u: (i64, string) = (1, 2)
    var v: (i32, i32) = (1, 2, 3)
    return first(x)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: tuple_literal_elementwise_rejected.k:13:33: error [SC028E]: cannot convert '(*i32, *i32)' to '(*const i32, *i32)'
// CHECK: tuple_literal_elementwise_rejected.k:14:28: error [SC028E]: cannot convert '(i64, i32)' to '(i64, string)'
// CHECK: tuple_literal_elementwise_rejected.k:14:32: error [SC028E]: cannot convert 'i32' to 'string'
// CHECK: tuple_literal_elementwise_rejected.k:15:25: error [SC028E]: cannot convert '(i32, i32, i32)' to '(i32, i32)'
// CHECK: tuple_literal_elementwise_rejected.k:16:12: error [SC063E]: no matching overload for call to 'first'
