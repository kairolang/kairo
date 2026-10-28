// Two declaration-scope `eval if`s that each read the other's record:
// neither member set is known before the other's, so once a round of the
// late fold decides nothing, both are reported (EVAL.md 4.2b).
class A {
    eval if is_trivially_copyable!(B) {
        var x: i32
    }
}

class B {
    eval if is_trivially_copyable!(A) {
        var y: i32
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: late_fold_cycle.k:5:13: error [SC001E]: the condition of an 'eval if' outside a function body must fold once types are resolved; it reads the members of 'B', which an 'eval if' that is not decided yet chooses
// CHECK: late_fold_cycle.k:11:13: error [SC001E]: the condition of an 'eval if' outside a function body must fold once types are resolved; it reads the members of 'A', which an 'eval if' that is not decided yet chooses
