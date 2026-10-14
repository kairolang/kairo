// --cmax-function-params errors on a function with more parameters than the
// limit; 0 is unlimited. Three parameters: a limit of 3 accepts, 2 rejects.

fn f(a: i32, b: i32, c: i32) -> i32 { return a + b + c }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-function-params=3 %s
// RUN: %kairo --type-check-only --cmax-function-params=0 %s
// RUN: { %kairo --type-check-only --cmax-function-params=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_function_params.k:4:{{[0-9]+}}: error [SC001E]: function has too many parameters (3, limit 2)
