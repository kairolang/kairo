// A String flag given without a value used to take the next element as its
// value, so `--xray -o out` swallowed `-o` and then parsed the old output path
// as a source file. A dash-led element is now reprocessed as a flag and the
// missing value is reported as U004E. A bare `-` stays a legal value (stdin),
// and a dash-led value is still spellable with `=`.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --xray -o %t.out 2>&1 || true; } | %FileCheck %s
// CHECK: error [U004E]: flag '--xray' requires a value but none was provided
// CHECK-NOT: no such file
// RUN: %kairo %s --type-check-only --xray=-weird
// RUN: %kairo %s --type-check-only --xray none
