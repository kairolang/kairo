// --ld-flags forwards a raw token to the linker line; it is repeatable and
// keeps command-line order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args --ld-flags=-fooA --ld-flags=-fooB | %FileCheck %s
// RUN: %kairo %s --print-ld-args --ld-flags -fooA --ld-flags -fooB | %FileCheck %s
// CHECK: -fooA -fooB
