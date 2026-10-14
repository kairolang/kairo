// --quiet drops warnings, notes and remarks; errors still print. This file's
// warning (SC005W) is the one that must disappear, and the error (R020E) the
// one that must survive.
fn f(__x: i32) -> i32 { return __x }
fn main() -> i32 { var a: i32 = u1; return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=LOUD
// RUN: { %kairo %s --type-check-only --quiet 2>&1 || true; } | %FileCheck %s --check-prefix=QUIET --implicit-check-not=warning
// LOUD: warning [SC005W]: parameter name is reserved
// QUIET: error [R020E]: use of undeclared identifier 'u1'
