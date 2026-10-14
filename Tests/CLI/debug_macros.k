// --debug-macros adds -debug-info-macro to the cc1 invocation, but only when
// debug info is on (-g). Without -g it is ignored, and -g0 turns it off.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -g --print-clang-args | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s -g --debug-macros --print-clang-args | %FileCheck %s --check-prefix=MACRO
// RUN: %kairo %s --debug-macros --print-clang-args | %FileCheck %s --check-prefix=NOG
// RUN: %kairo %s -g0 --debug-macros --print-clang-args | %FileCheck %s --check-prefix=NOG
// ON-NOT:    -debug-info-macro
// MACRO:     -debug-info-macro
// NOG-NOT:   -debug-info-macro
