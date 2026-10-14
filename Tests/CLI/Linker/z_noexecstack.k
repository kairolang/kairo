// --z-noexecstack passes -z noexecstack to the linker.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --z-noexecstack --print-ld-args | %FileCheck %s
// CHECK: ld.lld
// CHECK-SAME: -z noexecstack
