// --g0 (registry name no-debug-info) wins over -g wherever it sits on the
// command line, so a build can append it to turn debug info off. Plain -g
// is checked too, so the absence below is the flag's doing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-clang-args -g | %FileCheck %s --check-prefix=ON
// ON: -debug-info-kind=

// RUN: %kairo %s --print-clang-args -g --g0 | %FileCheck %s --check-prefix=OFF
// RUN: %kairo %s --print-clang-args --g0 -g | %FileCheck %s --check-prefix=OFF
// OFF: -emit-obj
// OFF-NOT: -debug-info-kind
