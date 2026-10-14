// --version reports the triple a compile would target (--target when given)
// on the "target triple" row, and keeps the machine's own on a separate
// "host triple" row.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --version --target=aarch64-linux-gnu | %FileCheck %s
// CHECK: target triple:{{ +}}aarch64{{.*}}linux
// CHECK: host triple:
