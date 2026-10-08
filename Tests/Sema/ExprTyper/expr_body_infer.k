// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// An expression body with no written return type infers it from the body,
// and the call then converts like any value of that type: `g()` is an i32,
// widened to i64 implicitly.

fn g() = 5

fn use_g() -> i64 {
    var y: i64 = g()
    return y
}

// DIAG-NOT: error
// SEMA: CallExpr {{.*}}: i32
// SEMA: g() -> i32
