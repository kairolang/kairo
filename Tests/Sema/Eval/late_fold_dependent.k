// A declaration-scope `eval if` chooses members once for every instance of
// a generic, and a generic is one C++ template with no class-scope
// `if constexpr` (MONO.md §2): a condition on a type parameter is an error
// whose note spells the partial specialization that selects a type instead.
// The same kind of condition naming no parameter folds (EVAL.md 4.2b).
struct Plain { var x: i32 }

class <T> Holder {
    eval if is_trivially_copyable!(T) {
        var fast: T
    } else {
        var slow: *T
    }
}

class <T> Fine {
    eval if is_trivially_copyable!(Plain) {
        var v: T
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: late_fold_dependent.k:9:13: error [SC132E]: a declaration-scope 'eval if' cannot depend on a type parameter; select a type instead
// CHECK-NEXT: late_fold_dependent.k:8:11: note [SC132N]: declare 'class <T> Holder<T> requires <condition>' once per member set: each a partial specialization of 'Holder' whose body holds that set
