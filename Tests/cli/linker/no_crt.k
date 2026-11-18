// --no-crt drops the C runtime startup objects from the link line and makes
// the entry point `main` directly, since nothing else would call it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo --target=x86_64-linux-musl --print-ld-args --no-crt %s | %FileCheck %s
// CHECK-NOT: crt1.o
// CHECK-NOT: crtbegin.o
// CHECK: -e main
