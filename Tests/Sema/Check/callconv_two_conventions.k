// A function has one calling convention: two different ones are SC133E,
// naming both. The same one twice is only redundant.

@preserve_most @preserve_all
priv fn both(n: usize) -> usize { return n }

@preserve_none @preserve_most
priv fn other(n: usize) -> usize { return n }

@preserve_most @preserve_most
priv fn twice(n: usize) -> usize { return n }

fn main() -> i32 { return (both(0) + other(0) + twice(0)) as i32 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: callconv_two_conventions.k:4:{{[0-9]+}}: error [SC133E]: '@preserve_most' and '@preserve_all' cannot both be on one function
// CHECK-DAG: callconv_two_conventions.k:7:{{[0-9]+}}: error [SC133E]: '@preserve_none' and '@preserve_most' cannot both be on one function
// CHECK-NOT: callconv_two_conventions.k:10:{{.*}}error
// CHECK-NOT: SC13{{[4-7]}}E
