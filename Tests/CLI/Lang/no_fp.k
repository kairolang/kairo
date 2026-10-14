// --no-fp rejects floating point in the program's own files: a float literal,
// a float-typed expression, and a float-typed parameter. Integer code is
// untouched. Without the flag the same file is accepted.

fn lit() -> i32 {
    var x: f64 = 1.5
    return 0
}

fn param(a: f32) -> i32 {
    return 0
}

fn ints(a: i32) -> i32 { return a + 1 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-fp %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_fp.k:6:{{[0-9]+}}: error [SC001E]: a floating-point literal is not allowed when floating point is disabled
// CHECK: no_fp.k:10:{{[0-9]+}}: error [SC001E]: a floating-point parameter is not allowed when floating point is disabled
