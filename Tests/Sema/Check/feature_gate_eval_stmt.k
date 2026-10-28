// An `eval for` directly in a module or class body parses
// (Tests/Parser/Grammar/eval_stmt_in_body.k) but nothing unrolls it there
// yet, so FeatureGateCheck reports it, once per statement, as SC116E. An
// `eval if` there is folded (EvalIfFolding, EVAL.md §4) and is no longer
// gated: the untaken branch is discarded before it is resolved, so its
// `"no"` into an `i32` is not reported, and the taken branch's `g` is the
// module's.

module m {
    eval if true { pub fn g() -> i32 { return 1 } }
    else { pub fn g() -> i32 { return 2 } }
    fn after() -> i32 { return 4 }
}

class K {
    var a: i32
    eval for i in 0..2 { var t: i32 = 0 }
    eval if false { var bad: i32 = "no" }
    fn b(self) -> i32 { return self.a }
}

fn main() -> i32 { return m::after() + m::g() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: feature_gate_eval_stmt.k:17:5: error [SC116E]: an 'eval for' in a module or class body is not yet supported
