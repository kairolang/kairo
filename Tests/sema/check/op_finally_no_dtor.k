// `x.finally()` on a local whose type is trivially destroyed runs nothing:
// it is accepted with a warning (SC305W), not an error.

class Plain { var a: i32 = 0 }

fn main() -> i32 {
    var p = Plain()
    p.finally()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: op_finally_no_dtor.k:8:5: warning [SC305W]: finally() has no effect on 'p'; its type 'Plain' is trivially destroyed
