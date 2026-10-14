// --dynamic-linker overrides the interpreter path on a dynamically linked
// (gnu) target's ld line.
// REQUIRES: bundled-sysroot

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --target=x86_64-linux-gnu --dynamic-linker=/lib/foo.so --print-ld-args | %FileCheck %s
// CHECK: -dynamic-linker /lib/foo.so
