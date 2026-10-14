// --cmax-macro-depth=N caps C macro expansion depth.

macro m1!() { x }
macro m2!() { (m1!() + 0) }
macro m3!() { (m2!() + 0) }
macro m4!() { (m3!() + 0) }
fn main() -> i32 { var x = 1; return m4!(); }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-macro-depth=2 2>&1 || true; } | %FileCheck %s
// CHECK: error [R008E]: macro expansion depth limit (2) exceeded
