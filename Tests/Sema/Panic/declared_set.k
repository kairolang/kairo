// A declared set `panic(E1, E2)` fixes what may leave (PANIC.md §2.2): a
// type panicked or propagated outside it is an error at the `panic` or the
// call, with a note at the callee and an edit adding the type to the list.
// Inferred sets are solved to a fixpoint over recursion (§2.5): `even` and
// `odd` call each other, and each set holds both types.
//
// A re-panic `panic e` of a catch binding propagates the caught type
// (§3.4); one of a bare arm's binding propagates whatever that arm caught.

struct EvenError { var n: i32 }
struct OddError  { var n: i32 }
struct Other     { var n: i32 }

fn even(n: i32) panic -> i32 {
    if n == 0 { panic EvenError { n: 0 } }
    return odd(n - 1)
}

fn odd(n: i32) panic -> i32 {
    if n == 1 { panic OddError { n: 1 } }
    return even(n - 1)
}

// The recursion's set is {EvenError, OddError}: OddError is outside.
fn only_even(n: i32) panic(EvenError) -> i32 {
    return even(n)
}

// Both, in either order: accepted.
fn both(n: i32) panic(OddError, EvenError) -> i32 {
    return odd(n)
}

fn raises_other(n: i32) panic(EvenError) -> i32 {
    if n < 0 { panic Other { n: n } }
    return n
}

// The typed arm re-panics EvenError; the bare arm takes OddError.
fn repanic_typed(n: i32) panic -> i32 {
    try {
        return even(n)
    } catch e: EvenError {
        panic e
    } catch {
        return 0
    }
}

fn user_typed(n: i32) panic(OddError) -> i32 {
    return repanic_typed(n)
}

// The bare arm's binding is whatever the arm caught: here both types.
fn repanic_bare(n: i32) panic -> i32 {
    try {
        return even(n)
    } catch e {
        panic e
    }
}

fn user_bare(n: i32) panic(EvenError) -> i32 {
    return repanic_bare(n)
}

fn main() -> i32 {
    try {
        return only_even(1) + both(2) + raises_other(3) + user_typed(4) + user_bare(5)
    } catch {
        return 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: declared_set.k:26:12: error [SC001E]: 'OddError' is not in the declared panic set of 'only_even'
// CHECK-NEXT: fix-it:"{{.*}}declared_set.k":{25:37-25:37}:", OddError"
// CHECK-NEXT: declared_set.k:14:1: note [SC001N]: 'even' is declared 'panic' here
// CHECK: declared_set.k:35:16: error [SC001E]: 'Other' is not in the declared panic set of 'raises_other'
// CHECK-NEXT: fix-it:"{{.*}}declared_set.k":{34:40-34:40}:", Other"
// CHECK: declared_set.k:51:12: error [SC001E]: 'EvenError' is not in the declared panic set of 'user_typed'
// CHECK-NEXT: fix-it:"{{.*}}declared_set.k":{50:37-50:37}:", EvenError"
// CHECK-NEXT: declared_set.k:40:1: note [SC001N]: 'repanic_typed' is declared 'panic' here
// CHECK: declared_set.k:64:12: error [SC001E]: 'OddError' is not in the declared panic set of 'user_bare'
// CHECK-NEXT: fix-it:"{{.*}}declared_set.k":{63:37-63:37}:", OddError"
// CHECK-NEXT: declared_set.k:55:1: note [SC001N]: 'repanic_bare' is declared 'panic' here
