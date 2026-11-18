// --resource-dir replaces the clang resource directory in all three places the
// cc1 invocation names it, so a bad value cannot leave a stale header root.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args --resource-dir=/my/res | %FileCheck %s
// CHECK:      -resource-dir /my/res
// CHECK-SAME: -isystem /my/res/include
// CHECK-SAME: -internal-isystem /my/res/include
