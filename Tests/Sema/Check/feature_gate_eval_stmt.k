// An `eval if` / `eval for` directly in a module or class body parses
// (Tests/Parser/Grammar/eval_stmt_in_body.k) but nothing chooses its branch
// or hoists that branch's declarations yet, so FeatureGateCheck reports it,
// once per statement, as SC116E -- before, the bodies rejected it in the
// parser (S046E / S048E). The two `g`s are in different branches, so they
// are not a redefinition; a mistake inside a branch is still reported.

module m {
    eval if true { fn g() -> i32 { return 1 } }
    else { fn g() -> i32 { return 2 } }
    fn after() -> i32 { return 4 }
}

class K {
    var a: i32
    eval for i in 0..2 { var t: i32 = 0 }
    eval if false { var bad: i32 = "no" }
    fn b(self) -> i32 { return self.a }
}

fn main() -> i32 { return m::after() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: feature_gate_eval_stmt.k:9:5: error [SC116E]: an 'eval if' in a module or class body is not yet supported
// CHECK: feature_gate_eval_stmt.k:16:5: error [SC116E]: an 'eval for' in a module or class body is not yet supported
// CHECK: feature_gate_eval_stmt.k:17:5: error [SC116E]: an 'eval if' in a module or class body is not yet supported
// CHECK: feature_gate_eval_stmt.k:17:36: error [SC028E]: cannot convert 'string' to 'i32'
