// -L / --lib-dir add library search paths to the link line, in the order given
// and in all four spellings (separate, attached, =value).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ld-args -L /x/lib --lib-dir=/y -L/z | %FileCheck %s
// RUN: %kairo %s --print-ld-args --lib-dir /w | %FileCheck %s --check-prefix=SEP
// CHECK: -L/x/lib -L/y -L/z
// SEP: -L/w
