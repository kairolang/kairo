// --export-dynamic is forwarded to the linker invocation so the executable's
// symbols are visible to dlopen'd code.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --export-dynamic --print-ld-args | %FileCheck %s
// CHECK: ld.lld
// CHECK-SAME: --export-dynamic
