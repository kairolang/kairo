// --print-macros lists the preprocessor's macro table: one row per macro with
// its name, parameter count and definition location. It was a stub that
// printed only a header.

macro twice!(a, b) { a + b }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-macros | %FileCheck %s
// CHECK: -- macro table:
// CHECK: macro twice: 2 param(s), defined at {{.*}}print_macros.k:{{[0-9]+}}:{{[0-9]+}}
