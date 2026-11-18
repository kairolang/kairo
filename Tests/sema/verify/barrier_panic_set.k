// A function's or a closure's `panic(...)` set is walked by the Verify
// passes like every other part of the signature. A closure written inside
// the set is its own barrier: a `break` or `continue` in it targets no loop
// (SC013E), and a `jump!` in it names no label of its own frame (SC006E).
// Verify errors stop the run before names are bound, so nothing else is
// reported.

struct E { var code: i32 }

fn f() panic(typeof(fn () -> E { break; return E { code: 1 } }())) -> i32 {
    return 0
}

fn g() -> i32 {
    var c = fn () panic(typeof(fn () -> E { continue; return E { code: 1 } }())) -> i32 { return 0 }
    return 0
}

fn h() panic(typeof(fn () -> E { jump!(nowhere); return E { code: 1 } }())) -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: barrier_panic_set.k:10:34: error [SC013E]: `break` outside of a loop
// CHECK-DAG: barrier_panic_set.k:15:45: error [SC013E]: `continue` outside of a loop
// CHECK-DAG: barrier_panic_set.k:19:34: error [SC006E]: `jump!` target is not declared by any `label!` in this function
