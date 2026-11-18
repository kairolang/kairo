// XFAIL: *
// "Both sides must be the same underlying type" (nullables.mdx, Null
// coalescing). `a ?? 1.5` with `a: i32?` is accepted and widened to `f64`,
// while `a ?? flag` with a `bool` right side is rejected (SC033E, "have no
// common type"). The mixed numeric case should be rejected the same way.

fn mixed(a: i32?) -> f64 {
    var v = a ?? 1.5 // expect: SC033E
    return v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: bug_coalesce_mixed_numeric_types.k:8:{{[0-9]+}}: error [SC033E]
