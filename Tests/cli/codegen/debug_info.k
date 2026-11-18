// -g turns on DWARF 5 in the cc1 invocation; without it no debug-info kind is
// passed, so default builds do not pay for debug sections.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args -g | %FileCheck %s --check-prefix=G
// G: -debug-info-kind=constructor -dwarf-version=5
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=NOG
// NOG-NOT: -debug-info-kind
