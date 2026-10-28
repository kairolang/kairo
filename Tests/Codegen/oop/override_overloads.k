// Overrides and same-name methods called on the derived type, beside
// overloads that differ by parameters. MemberLookup merges the base's set
// with the derived class's (RESOLUTION.md §2b), and overload resolution
// applies C++'s using-declaration rule to it (OverloadResolution::_hide):
// a derived method with the same parameters
// and `self` constness overrides or hides the base's, and the rest rank
// as one set. The emitted class carries a `using Base::name;` for each
// shared name, which is C++'s rule for exactly that set, so the base
// overload Kairo picked is the one C++ calls.
//
// Each check returns its own code on failure; 0 is a pass.

class A {
    virtual fn k(self) -> i32 { return 1 }
    fn n(self) -> i32 { return 10 }
    fn c(const self) -> i32 { return 100 }
    fn f(self, x: i32) -> i32 { return 1000 }
    fn f(self, x: f64) -> i32 { return 2000 }
    virtual fn v(self, x: i64) -> i32 { return 5 }
    fn q(self) -> i32 { return 7 }
}

class D derives A {
    override fn k(self) -> i32 { return 2 }
    fn n(self) -> i32 { return 20 }
    // `const self` on both: a non-const object still prefers the derived
    // one, by the receiver, not by the const-ness tiebreak.
    fn c(const self) -> i32 { return 200 }
    fn f(self, x: i32) -> i32 { return 3000 }
    // A base's plain `self` beside the derived class's `const self`: not
    // the same signature, so both stay, and a non-const object prefers
    // `self` -- the base's, as C++ picks it through the `using A::q;`.
    fn q(const self) -> i32 { return 8 }
}

class E derives D {
    override fn k(self) -> i32 { return 3 }
    override fn v(self, x: i64) -> i32 { return 6 }
}

class <T> GB {
    virtual fn g(self) -> i32 { return 5 }
    fn h(self, t: T) -> i32 { return 50 }
}

class GD derives GB<i32> {
    override fn g(self) -> i32 { return 6 }
    fn h(self, t: f64) -> i32 { return 60 }
}

fn main() -> i32 {
    var d = D()
    if d.k() != 2 { return 1 }                  // override on the derived value
    var *pd = &d
    if pd->k() != 2 { return 2 }                // ... and through a *D
    if d.n() != 20 { return 3 }                 // non-virtual same name
    if d.c() != 200 { return 4 }                // const self on both
    var x: i32 = 1
    if d.f(x) != 3000 { return 5 }              // same signature: the derived one
    var y: f64 = 1.0
    if d.f(y) != 2000 { return 6 }              // the base's overload, not hidden
    var e = E()
    if e.k() != 3 { return 7 }                  // two levels down
    if e.n() != 20 { return 8 }                 // the nearer of two bases' versions
    var w: i64 = 4
    if e.v(w) != 6 { return 9 }
    var a: *A = &e
    if a->k() != 3 { return 10 }                // virtual through the base pointer
    if a->n() != 10 { return 11 }               // static type picks A's
    if D::k(d) != 2 { return 12 }               // qualified, on the derived value
    var g = GD()
    if g.g() != 6 { return 13 }                 // a generic base
    if g.h(x) != 50 { return 14 }               // the base's h(T = i32)
    if g.h(y) != 60 { return 15 }               // the derived h(f64)
    var gb: *GB<i32> = &g
    if gb->g() != 6 { return 16 }
    if d.q() != 7 { return 17 }
    var cd: *const D = &d
    if cd->q() != 8 { return 18 }               // a const object: only the derived one
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
