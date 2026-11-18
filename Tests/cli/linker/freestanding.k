// --freestanding drops the crt objects and the default libraries from the
// link line and names the ELF entry point instead, so a kernel or bare-metal
// image is not dragged through libc startup.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --freestanding | %FileCheck %s
// CHECK-NOT: crt1.o
// CHECK-NOT: -lc
// CHECK:     -e main
