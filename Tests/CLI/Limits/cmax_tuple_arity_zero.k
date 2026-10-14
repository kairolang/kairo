// --cmax-tuple-arity=0 means unlimited (per its help); it used to reject every
// tuple because the parser compared the arity against 0. A 5-tuple must be
// accepted with 0, and still rejected with a cap of 2. See
// cmax_tuple_arity.k for the plain cap case.

fn f(a: (i32, i32, i32, i32, i32)) -> i32 { return 0 }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-tuple-arity=0 %s
// RUN: { %kairo --type-check-only --cmax-tuple-arity=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: tuple arity exceeds the maximum of 2 (got 5)
