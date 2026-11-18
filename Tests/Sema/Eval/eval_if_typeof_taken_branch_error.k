// `eval if typeof A == B` between concrete types folds at compile time:
// the taken branch is type-checked and its errors are reported (SC028E at
// line 7), the untaken branch is dropped before typing and is silent.

fn main() -> i32 {
    eval if typeof i32 == i32 {
        var x: i32 = "taken"
    } else {
        var y: i32 = "untaken"
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_if_typeof_taken_branch_error.k:7:{{[0-9]+}}: error [SC028E]: cannot convert 'string' to 'i32'
