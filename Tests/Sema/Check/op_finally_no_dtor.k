// XFAIL: *
// Waits on the planned 0.3 design: `x.finally()`
// is an explicit early destructor call; before 0.3 it is a "not implemented
// yet" error (SC116E) for every receiver. This is the §77 assertion for a
// class with no declared destructor, kept as written.

class Plain { var a: i32 = 0 }

fn main() -> i32 {
    var p = Plain()
    p.finally()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: op_finally_no_dtor.k:10:5: error [SC102E]: 'Plain' declares no destructor for 'finally()' to run; declare 'fn op finally(self)' (a body, or '= default')
