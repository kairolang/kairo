// Dereferencing a dependent value that is not a pointer in a generic body is
// an error at the dereference, the same as for a concrete non-pointer.

fn <T> first(a: T) -> T {
    var m = *a
    return m
}

fn main() -> i32 {
    return first(4)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I011W'
// CHECK: generic_deref_of_pointer_has_type_reject.k:5:13: error [SC070E]: cannot dereference non-pointer type 'T'
