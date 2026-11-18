// -E / --error <CODE> promotes that diagnostic to an error. The code is
// accepted as a separate argument (-E X, --error X) and as --error=X. SC005 is
// a warning-class rule here, so seeing it as error [SC005E] proves promotion.

fn f(__x: i32) -> i32 { return __x }
fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -E SC005 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only --error=SC005 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only --error SC005 2>&1 || true; } | %FileCheck %s
// CHECK: error [SC005E]: parameter name is reserved
