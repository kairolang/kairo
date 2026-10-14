// --sysroot reaches cc1 as -isysroot and the system include roots when
// --target has no bundled sysroot to override it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --target=aarch64-unknown-none --sysroot=/nonexistent | %FileCheck %s
// CHECK:      clang -cc1 -triple aarch64-unknown-none
// CHECK-SAME: -isystem /nonexistent/include/c++/v1
// CHECK-SAME: -isystem /nonexistent/include
// CHECK-SAME: -isysroot /nonexistent
