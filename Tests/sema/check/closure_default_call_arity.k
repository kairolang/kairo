// A call through a closure local takes the closure's defaults for omitted
// trailing arguments, and still checks the count: too few (the first
// parameter has no default) and too many are SC099E, while `g(1)` and
// `g(1, 2)` are clean.

fn main() -> i32 {
    var g = fn (a: i32, b: i32 = 4) -> i32 { return a + b }
    var r = g(1)
    r += g(1, 2)
    r += g()
    r += g(1, 2, 3)
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: closure_default_call_arity.k:10:{{[0-9]+}}: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 0 given
// CHECK: closure_default_call_arity.k:11:{{[0-9]+}}: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 3 given
