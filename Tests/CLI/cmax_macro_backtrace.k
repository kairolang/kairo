// --cmax-macro-backtrace=N caps the "in expansion of macro" notes at N levels
// and adds a truncation note.

macro m1!() { var x: = ; }
macro m2!() { m1!() }
macro m3!() { m2!() }
macro m4!() { m3!() }
macro m5!() { m4!() }
fn main() -> i32 { m5!() return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-macro-backtrace=2 2>&1 || true; } | %FileCheck %s
// CHECK: error [S053E]: expected type, found '='
// CHECK: note [I900N]: in expansion of macro 'm1!()' invoked here
// CHECK: note [I900N]: in expansion of macro 'm2!()' invoked here
// CHECK: note [I900N]: macro expansion chain truncated after 2 levels
