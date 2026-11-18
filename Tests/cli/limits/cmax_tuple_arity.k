// --cmax-tuple-arity caps tuple arity for C++ interop; a tuple type wider
// than the cap is rejected in type checking with the cap and the actual
// arity in the message.

fn f(a: (i32, i32, i32)) -> i32 { return 0 }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only --cmax-tuple-arity=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: [S055E]
// CHECK-SAME: tuple arity exceeds the maximum of 2 (got 3)
