// -A silences warnings, notes and remarks only. An error with an allowed code
// still prints and still fails the build; silencing it would let a broken
// program compile.

fn main() -> i32 { var a: i32 = u1; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -A R020 2>&1 || true; } | %FileCheck %s
// CHECK: error [R020E]: use of undeclared identifier 'u1'
