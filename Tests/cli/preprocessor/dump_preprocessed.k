// --dump-preprocessed prints the token stream after macro expansion and
// compiles nothing; tokens are space-separated and the macro definition line
// is gone, so expansion is observable without running later phases.

macro five!() { 5 }
fn main() -> i32 { return five!() }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s
// CHECK: fn main ( ) -> i32 { return 5 }
