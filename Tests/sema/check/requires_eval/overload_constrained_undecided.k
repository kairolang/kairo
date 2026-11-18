// Constraint ordering and the generic-body error stay out of cases they do
// not cover, and these calls remain SC064E. A clause Kairo cannot decide
// for concrete arguments (the `sizeof` of a class) orders nothing, since
// clang may find it false and call the other candidate. Such a clause at an
// ordinary call is not a generic body's open parameter (SC320E). Two
// parameter lists of different lengths, a defaulted parameter included,
// are not equivalent, so their constraints order nothing, as in C++.

interface Shout {
    fn shout(const self) -> i32
}

class Big {
    pub var a: i64 = 1
    pub var b: i64 = 2

    pub fn Big(self) {}

    pub fn shout(const self) -> i32 {
        return 1
    }
}

fn <T> c(const x: T) -> i32 requires sizeof T <= 8 {
    return 1
}

fn <T> c(const x: T) -> i32 {
    return 2
}

fn <T> w(const x: T) -> i32 requires sizeof T <= 4 {
    return 10
}

fn <T> w(const x: T) -> i32 requires sizeof T > 4 {
    return 20
}

fn <T> f(const x: T) -> i32 requires T impl Shout {
    return 100
}

fn <T> f(const x: T, y: i32 = 0) -> i32 {
    return 200
}

fn main() -> i32 {
    var b = Big()
    return c(b) + w(b) + f(b)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: overload_constrained_undecided.k:50:12: error [SC064E]: call to 'c' is ambiguous
// CHECK: overload_constrained_undecided.k:50:19: error [SC064E]: call to 'w' is ambiguous
// CHECK: overload_constrained_undecided.k:50:26: error [SC064E]: call to 'f' is ambiguous
