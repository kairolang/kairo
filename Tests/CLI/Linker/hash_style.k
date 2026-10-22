// --hash-style reaches the linker line on a glibc target, replacing the
// default gnu style.
// REQUIRES: sysroot-x86_64-linux-gnu

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --target=x86_64-linux-gnu --hash-style=sysv --print-ld-args | %FileCheck %s
// CHECK: --hash-style=sysv
