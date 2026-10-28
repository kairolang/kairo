eval fn twice(x: usize) -> usize { return x * 2 }

fn take4(const a: [i32; 4]) -> i32 { return a[3] }

fn main() -> i32 {
    var c: [i32; twice(2)] = [1, 2, 3, 4]
    var d: [i32; twice(2)] = [5, 6, 7, 8]
    var p: *[i32; twice(2)] = &c
    p = &d                                   // the same expression: one type
    return take4(c)                          // not [i32; 4], though C++ says 4
}

// EVAL.md 0.2: a computed extent's type identity is the structure of its
// expression, as C++'s is for a dependent expression before instantiation:
// `[i32; twice(2)]` is `[i32; twice(2)]` everywhere, and is not `[i32; 4]`
// even though twice(2) == 4. Sema never computes it.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: computed_extent_identity.k:10:12: error [SC063E]: no matching overload for call to 'take4'
// CHECK-NEXT: computed_extent_identity.k:3:1: note [I900N]: candidate not viable: cannot convert argument of type '[i32; twice(2)]' to parameter 'a' of type '[i32; 4]'
