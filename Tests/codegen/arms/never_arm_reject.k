// A `!` arm joins any type, but an arm of type void is not a never arm:
// `if c => k else => nothing()` in an i32 context is a branch type mismatch.

fn nothing() { }

fn pick(c: bool, k: i32) -> i32 {
    var v: i32 = if c => k else => nothing()
    return v
}

fn main() -> i32 {
    return pick(true, 9)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: never_arm_reject.k:7:36: error [SC039E]: the 'else' branch has type 'void', which does not unify with the earlier 'i32'
