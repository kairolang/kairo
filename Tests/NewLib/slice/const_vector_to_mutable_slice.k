// A const vector, or a read-only `[const T;]` view, does not convert to a
// mutable slice: the conversion is refused, so a write cannot reach the
// vector's elements through it.

fn bump(s: [i32;]) { s[0] += 1 }

fn through_const(const v: [i32]) {
    var m: [i32;] = v
}

fn through_view() {
    var v: [i32] = [1, 2]
    var w: [const i32;] = v
    bump(w)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: newlib
// RUN: { %kairo_new %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: const_vector_to_mutable_slice.k:8:21: error [SC028E]: cannot convert 'const [i32]' to '[i32;]'
// CHECK: const_vector_to_mutable_slice.k:14:5: error [SC063E]: no matching overload for call to 'bump'
// CHECK: const_vector_to_mutable_slice.k:5:1: note [I900N]: candidate not viable: cannot convert argument of type '[const i32;]' to parameter 's' of type '[i32;]'
