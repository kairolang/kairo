// --cmax-errors=0 means unlimited. It used to compare every error count
// against a limit of 0, so the very first error printed only "too many errors"
// and a broken program exited 0. All four errors must print and the notice
// must not.

fn main() -> i32 { var a: i32 = u1; var b: i32 = u2; var c: i32 = u3; var d: i32 = u4; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s
// CHECK: error [R020E]: use of undeclared identifier 'u1'
// CHECK: error [R020E]: use of undeclared identifier 'u2'
// CHECK: error [R020E]: use of undeclared identifier 'u3'
// CHECK: error [R020E]: use of undeclared identifier 'u4'
// CHECK-NOT: too many errors
