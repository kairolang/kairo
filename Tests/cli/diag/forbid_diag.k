// -F <code> forbids a diagnostic; it must win over an -A <code> allow of the
// same code, so the diagnostic is still reported as an error.

fn f(__x: i32) -> i32 { return __x }
fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -F SC005 -A SC005 2>&1 || true; } | %FileCheck %s
// CHECK: error [SC005E]: parameter name is reserved
