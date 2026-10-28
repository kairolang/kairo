// A declaration-scope `eval if` on a type fact may not declare a type
// (EVAL.md 4.2b): T resolves every use of one before the late fold says
// whether it exists.
struct Plain { var x: i32 }

eval if is_trivially_copyable!(Plain) {
    struct Inner { var y: i32 }
    fn ok() -> i32 { return 0 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: late_fold_type_in_branch.k:7:12: error [SC001E]: 'Inner' is declared in an 'eval if' whose condition reads a type fact; such a condition is decided after types are resolved, so its branches may declare only functions, constants and fields
