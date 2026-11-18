// An `eval for` range bound is evaluated at compile time, including an
// extension call in it: an extension that is not `eval` is rejected at the
// bound rather than reaching codegen.
extend i32 { fn twice(const self) -> i32 { return self * 2 } }
eval N: i32 = 2
fn b() -> i32 {
    var s = 0
    eval for i in 0..N.twice() { s += i }
    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E"
// CHECK: eval_for_bound_extension_reject.k:8:22: error [SC192E]: the upper bound of an 'eval for' range must be evaluable at compile time; this is a run-time value
