// --strip-debug is a linker-only switch: it reaches the ld line as
// --strip-debug and never turns into --strip-all.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args --strip-debug | %FileCheck %s
// CHECK: ld.lld
// CHECK-SAME: --strip-debug
// CHECK-NOT: --strip-all
