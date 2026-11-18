// --ld-flags forwards a raw token to the linker line; it is repeatable and
// keeps command-line order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args --ld-flags=-fooA --ld-flags=-fooB | %FileCheck %s
// CHECK: -fooA -fooB
// A dash-led value must be glued with `=`: the space form would otherwise
// let `--ld-flags -o` swallow the output flag, so it is rejected.
// RUN: { %kairo %s --print-ld-args --ld-flags -fooA 2>&1 || true; } | %FileCheck %s --check-prefix=SPACE
// SPACE: error [U004E]: flag '--ld-flags' requires a value but none was provided
