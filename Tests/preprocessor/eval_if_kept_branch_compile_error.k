// A `compile_error!` in an `eval if` branch that is kept fires, at file
// scope and in a function body alike.

macro ON!() { 1 }

fn main() -> i32 {
    eval if defined!(ON) {
        compile_error!("the kept branch was reached")
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_if_kept_branch_compile_error.k:8:9: error [R010E]: "the kept branch was reached"
