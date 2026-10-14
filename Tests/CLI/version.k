// --version / -V prints the installed-compiler banner and compiles nothing.
// The version string is date-stamped, so only its shape is pinned.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --version | %FileCheck %s
// RUN: %kairo -V | %FileCheck %s
// CHECK: installed version: kairo-
// CHECK: target triple:
// CHECK: thread model:
// CHECK: installed at:
