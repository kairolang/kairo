// -Xlinker passes one argument to the linker. It is a third spelling of
// --ld-flags: all spellings fill one list, so the arguments keep their
// command-line order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args -Xlinker=-fooA --ld-flags=-fooB --linker-arg=-fooC --Xlinker=-fooD | %FileCheck %s
// CHECK: -fooA -fooB -fooC -fooD
// The next word is the value when it does not start with a dash.
// RUN: %kairo %s --print-ld-args -Xlinker fooE --ld-flags=-fooF | %FileCheck %s --check-prefix=SPACE
// SPACE: fooE -fooF
