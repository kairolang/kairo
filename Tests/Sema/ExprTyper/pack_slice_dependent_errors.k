// A generic `...xs: T` is a `[T;]` in the body, so using it as some other
// type is an ordinary conversion error.

fn <T> gen(...xs: T) -> usize { return xs }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: pack_slice_dependent_errors.k:4:40: error [SC028E]: cannot convert '[T;]' to 'usize'
// CHECK-NOT: {{error|Internal Compiler Error}}
