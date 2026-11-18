// The deadness of an `eval if` branch is decided by its condition, so a
// branch that is kept is expanded in full: an unknown macro in it is an
// error.

fn unknown() -> i32 {
    eval if !defined!(__KAIRO_TEST_NO_SUCH_MACRO__) {
        return unknown_in_kept_branch!()
    }
    return 0
}

fn main() -> i32 { return unknown() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_if_kept_branch_errors.k:7:16: error [R013E]: unknown macro 'unknown_in_kept_branch!' (macros must be defined or imported before use)
