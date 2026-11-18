// In a generic body, a bound on the caller's parameter decides the
// `requires` clauses of the overloads it calls: `T impl Loud` makes
// `requires T impl Loud` hold and `requires !(T impl Loud)` fail, so the
// call resolves where it is written. A bound by an interface deriving the
// tested one decides it too. The emitted C++ resolves the same call per
// instance from the template heads, so the program exits 0 only when clang
// called the overload Kairo chose.

interface Loud {
    fn shout(const self) -> i32
}

interface Louder derives Loud {
    fn roar(const self) -> i32
}

class Horn {
    pub fn Horn(self) {}

    pub fn shout(const self) -> i32 {
        return 5
    }

    pub fn roar(const self) -> i32 {
        return 50
    }
}

fn <T> say(const x: T) -> i32 requires T impl Loud {
    return x.shout()
}

fn <T> say(const x: T) -> i32 requires !(T impl Loud) {
    return 0
}

fn <T impl Loud> relay(const x: T) -> i32 {
    return say(x)
}

fn <T impl Louder> relay_louder(const x: T) -> i32 {
    return say(x) + x.roar()
}

// With the bound deciding both clauses, constraint ordering applies too:
// the constrained overload beats the unconstrained one.
fn <T> pick(const x: T) -> i32 requires T impl Loud {
    return 100
}

fn <T> pick(const x: T) -> i32 {
    return 200
}

fn <T impl Loud> forward(const x: T) -> i32 {
    return pick(x)
}

fn main() -> i32 {
    var h = Horn()
    return relay(h) + relay_louder(h) + forward(h) - 160
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
