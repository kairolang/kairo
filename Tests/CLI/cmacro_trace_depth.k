// --cmacro-trace-depth bounds how deep --macro-debug traces nested macro
// expansions (visible with -v). Depth counts the splice stack.

macro m1!() { x }
macro m2!() { (m1!() + 0) }
macro m3!() { (m2!() + 0) }
macro m4!() { (m3!() + 0) }
fn main() -> i32 { var x = 1; return m4!(); }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --macro-debug -v --cmacro-trace-depth=1 2>&1 || true; } | %FileCheck %s
// CHECK: [macro-debug] expand 'm4!' depth=0
// CHECK: [macro-debug] expand 'm3!' depth=1
// CHECK-NOT: [macro-debug] expand 'm2!'
