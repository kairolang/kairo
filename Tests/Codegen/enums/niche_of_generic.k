// `__builtin_niche_of<T>()` is answered before any instantiation, so in a
// generic body, where T is the instance's, it has no answer: an error, not
// the declaration's placeholder 0.

fn <T> spare() -> u64 = __builtin_niche_of<T>()

fn main() -> i32 {
    return spare<*i32>() as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -c --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: niche_of_generic.k:5:25: error [SC001E]: '__builtin_niche_of' needs a type whose layout is known here; this one depends on a generic parameter
