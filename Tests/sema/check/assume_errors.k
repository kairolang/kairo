// `@assume(c)` takes exactly one condition and stands alone on its line:
// written before another statement on the same line it would read as an
// attribute of that statement, which it is not.

fn g() -> i32 { return 1 }

fn f(x: i32) -> i32 {
    @assume(x > 0) return g()
}

fn h(x: i32) -> i32 {
    @assume()
    @assume(x > 0, x < 9)
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: assume_errors.k:8:{{[0-9]+}}: error [SC148E]: @assume is a statement of its own; it does not attach to what follows on its line
// CHECK-DAG: assume_errors.k:12:{{[0-9]+}}: error [S080E]:
// CHECK-DAG: assume_errors.k:13:{{[0-9]+}}: error [S080E]:
