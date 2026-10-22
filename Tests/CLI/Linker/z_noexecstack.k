// --z-noexecstack passes -z noexecstack to the linker.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --z-noexecstack --print-ld-args | %FileCheck %s
// CHECK: ld.lld
// CHECK-SAME: -z noexecstack
