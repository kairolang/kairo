// Constraints order overloads only when the emitted C++ template heads
// carry them, so clang orders the same pair the same way. A `derives` test
// is not in the head: two overloads told apart only by one would be one
// C++ template, so Kairo keeps them ambiguous rather than accept a pair
// clang rejects as a redefinition.

interface Shout {
    fn shout(const self) -> i32
}

class Base {
    pub fn Base(self) {}
}

class Der derives Base {
    pub fn Der(self) {}

    pub fn shout(const self) -> i32 {
        return 1
    }
}

fn <T> a(const x: T) -> i32 requires T derives Base {
    return 1
}

fn <T> a(const x: T) -> i32 {
    return 2
}

fn <T> b(const x: T) -> i32 requires T impl Shout && T derives Base {
    return 10
}

fn <T> b(const x: T) -> i32 requires T impl Shout {
    return 20
}

fn main() -> i32 {
    var d = Der()
    return a(d) + b(d)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: overload_constrained_not_in_head.k:41:12: error [SC064E]: call to 'a' is ambiguous
// CHECK: overload_constrained_not_in_head.k:41:19: error [SC064E]: call to 'b' is ambiguous
