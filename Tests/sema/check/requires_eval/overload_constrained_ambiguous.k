// Constraint ordering stays ambiguous where neither candidate's clause
// subsumes the other's, as in C++ ([temp.constr.order]): two unrelated
// conformances; a negation, which is one atom identified by where it is
// written, so `!(T impl Shout)` in one overload is not the same atom as in
// another; and two heads that are not equivalent (the parameters swapped),
// whose constraints order nothing.

interface Shout {
    fn shout(const self) -> i32
}

interface Wave {
    fn wave(const self) -> i32
}

class Loud {
    pub fn Loud(self) {}

    pub fn shout(const self) -> i32 {
        return 1
    }

    pub fn wave(const self) -> i32 {
        return 2
    }
}

class OnlyWave {
    pub fn OnlyWave(self) {}

    pub fn wave(const self) -> i32 {
        return 3
    }
}

fn <T> unrelated(const x: T) -> i32 requires T impl Shout {
    return 1
}

fn <T> unrelated(const x: T) -> i32 requires T impl Wave {
    return 2
}

fn <T> negated(const x: T) -> i32 requires !(T impl Shout) {
    return 1
}

fn <T> negated(const x: T) -> i32 requires !(T impl Shout) && T impl Wave {
    return 2
}

fn <A, B> swapped(const a: A, const b: B) -> i32 requires A impl Shout {
    return 1
}

fn <B, A> swapped(const a: A, const b: B) -> i32 {
    return 2
}

fn main() -> i32 {
    var l = Loud()
    var w = OnlyWave()
    return unrelated(l) + negated(w) + swapped(l, l)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: overload_constrained_ambiguous.k:63:12: error [SC064E]: call to 'unrelated' is ambiguous
// CHECK: overload_constrained_ambiguous.k:63:27: error [SC064E]: call to 'negated' is ambiguous
// CHECK: overload_constrained_ambiguous.k:63:40: error [SC064E]: call to 'swapped' is ambiguous
// CHECK-NOT: error
