// --save-temps keeps the intermediate object next to the output in
// <output>.kobj/. Checked via a real link to a per-test path.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.out %t.out.kobj
// RUN: %kairo %s --save-temps -o %t.out
// RUN: ls %t.out.kobj | %FileCheck %s
// CHECK: .o
