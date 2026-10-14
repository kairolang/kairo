// -w suppresses warnings and reaches the clang invocation as a bare -w word.
// Absent without the flag, so the match cannot be some other token.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args -w | %FileCheck %s --check-prefix=W
// W: {{ }}-w{{ }}

// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=NOW
// NOW: -emit-obj
// NOW-NOT: {{ }}-w{{ }}
