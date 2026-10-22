// --rpath is repeatable and accepts both spellings. A static link has no
// dynamic section for the runtime path to live in, and the bundled musl
// sysroot is static-only, so there the pairs are dropped with one warning
// rather than emitted into a line where they could never take effect.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --rpath /r1 --rpath=/r2 2>&1 | %FileCheck %s
// CHECK: warning [L001W]: --rpath has no effect on a static link
// CHECK-NOT: -rpath
