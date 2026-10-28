// A Kairo-only trait needs a concrete type: C++ cannot tell a class from a
// struct, so a generic body's T has no answer.
fn <T> h() -> bool { return __builtin_is_class<T>() }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: kairo_trait_dependent.k:3:29: error [SC001E]: '__builtin_is_class' needs a concrete type; this one depends on a generic parameter
