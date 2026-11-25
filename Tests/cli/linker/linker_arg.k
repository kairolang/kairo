// --linker-arg passes one argument to the linker, after kairo's own. It is
// repeatable and a second spelling of --ld-flags: both fill one list, so the
// arguments keep their command-line order whichever spelling each has.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args --linker-arg=-fooA --ld-flags=-fooB --linker-arg=-fooC | %FileCheck %s
// CHECK: -fooA -fooB -fooC
// A dash-led value is glued with `=`, as for --ld-flags.
// RUN: { %kairo %s --print-ld-args --linker-arg -fooA 2>&1 || true; } | %FileCheck %s --check-prefix=SPACE
// SPACE: error [U004E]: flag '--linker-arg' requires a value but none was provided
