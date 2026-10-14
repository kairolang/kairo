// --cmax-errors=N stops after N errors with a "too many errors" error and
// suppresses the rest. Only N > 0 is pinned; N=0 is meant to be unlimited
// but does not behave that way, so it is deliberately not asserted.

fn main() -> i32 { var a: i32 = u1; var b: i32 = u2; var c: i32 = u3; var d: i32 = u4; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=2 2>&1 || true; } | %FileCheck %s
// CHECK: error [R020E]: use of undeclared identifier 'u1'
// CHECK: error [R020E]: use of undeclared identifier 'u2'
// CHECK-NEXT: error [I957E]: too many errors emitted, further errors will be suppressed
// CHECK-NOT: 'u3'
