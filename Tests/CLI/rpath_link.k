// --rpath-link forwards a search directory to the linker as -rpath-link so
// shared-library dependencies resolve at link time without being embedded.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args --rpath-link /r2 | %FileCheck %s
// CHECK: -rpath-link /r2
