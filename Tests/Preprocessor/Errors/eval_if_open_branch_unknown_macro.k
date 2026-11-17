// An unknown macro in an `eval if` branch that only Sema can decide is
// R013E when the branch is kept, once, at the invocation, and nothing when
// the branch is discarded. A branch that stays `if constexpr` is kept.

macro wrap!() { missing_inner!() }

eval if defined!(__KAIRO_TEST_NO_SUCH_MACRO__) {
    eval A: i32 = discarded_a!()
} else {
    eval A: i32 = kept_a!()
}

eval if defined!(__KAIRO_TEST_NO_SUCH_MACRO__) {
    eval B: i32 = 1
} else if !defined!(__KAIRO_TEST_NO_SUCH_MACRO__) {
    eval B: i32 = wrap!()
} else {
    eval B: i32 = discarded_b!()
}

fn <T> stays(x: T) -> i32 {
    eval if sizeof T > 4 || defined!(__KAIRO_TEST_NO_SUCH_MACRO__) {
        return kept_c!()
    }

    return 0
}

fn main() -> i32 { return A + B + stays(1) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: discarded_
// CHECK: eval_if_open_branch_unknown_macro.k:10:19: error [R013E]: unknown macro 'kept_a!' (macros must be defined or imported before use)
// CHECK-NOT: discarded_
// CHECK: eval_if_open_branch_unknown_macro.k:16:19: error [R013E]: unknown macro 'missing_inner!' (macros must be defined or imported before use)
// CHECK-NEXT: eval_if_open_branch_unknown_macro.k:5:17: note [I900N]: expanded from here
// CHECK-NOT: discarded_
// CHECK: eval_if_open_branch_unknown_macro.k:23:16: error [R013E]: unknown macro 'kept_c!' (macros must be defined or imported before use)
// CHECK-NOT: discarded_
