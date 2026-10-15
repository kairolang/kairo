// Destructuring a struct by field name has no lowering yet; FeatureGateCheck
// reports it (SC116E) so TupleLowering's ICE on one stays an invariant. A
// tuple's positional form is lowered and passes.

struct P { var x: i32  var y: i32 }

fn by_name(p: P) -> i32 {
    var {x, y} = p
// DIAG: feature_gate_destructure.k:[[@LINE-1]]:5: error [SC116E]: destructuring a struct by field name is not yet supported
    return x + y
}

fn by_position(t: (i32, i32)) -> i32 {
    var (a, b) = t
    return a + b
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
