// --unwindlib rejects unknown values with a linker-category error naming the
// accepted ones.
// REQUIRES: bundled-sysroot

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --target=x86_64-linux-musl --print-ld-args --unwindlib=bogus 2>&1 || true; } | %FileCheck %s
// CHECK: error [L001E]: unknown --unwindlib value bogus; expected libunwind, libgcc or none
