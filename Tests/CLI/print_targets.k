// --print-targets lists the LLVM backends linked into this compiler and
// exits without compiling. Only x86-64 is asserted: the rest of the list is
// whatever the build linked in, so pinning it would be machine-dependent.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --print-targets | %FileCheck %s
// CHECK: Registered targets:
// CHECK: x86-64
