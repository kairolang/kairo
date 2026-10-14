// --embed-source only takes effect together with -g: it adds -gembed-source
// to cc1, and is silently ignored without debug info.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -g --embed-source --print-clang-args | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s -g --print-clang-args | %FileCheck %s --check-prefix=OFF
// RUN: %kairo %s --embed-source --print-clang-args | %FileCheck %s --check-prefix=OFF
// ON:  -gembed-source
// OFF-NOT: -gembed-source
