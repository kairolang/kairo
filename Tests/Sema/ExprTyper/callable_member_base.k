// A member read through a function that has no value (a generic function
// short of its arguments, here in its own body) is SC100E at the chain, not
// a dependent chain left for codegen with no callee.

interface Named {
    fn name_len(const self) -> i32
}

fn <T impl Named> show(t: T) -> i32 {
    return show.name_len()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: callable_member_base.k:10:12: error [SC100E]: cannot access a member of a function; call it first
// CHECK-NOT: {{error|Internal Compiler Error}}
