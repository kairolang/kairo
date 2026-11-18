// --rpath-link forwards a search directory to the linker as -rpath-link so
// shared-library dependencies resolve at link time without being embedded.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --rpath-link /r2 | %FileCheck %s
// CHECK: -rpath-link /r2
