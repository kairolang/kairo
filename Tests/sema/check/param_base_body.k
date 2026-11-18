// What the body of a class deriving its own type parameter may use
// (classes-inheritance.mdx, Deriving a type parameter): exactly what the
// parameter's `derives` bound promises, looked up where the class is
// written. A member only some argument has is R025E in the body, though
// `Good<Wide>` would have it; from outside, `g.only_wide()` on a
// `Good<Wide>` is that instance's own member and is fine. A base
// initializer cannot be written, because the bound promises no constructor:
// the base is built by its default constructor (SC351E).

class Base {
    pub var n: i32 = 3
    pub fn Base(self) { }
    pub fn Base(self, k: i32) { self.n = k }
    pub virtual fn begin(self) -> i32 { return 1 }
}

class Wide derives Base {
    pub fn Wide(self) { }
    pub fn only_wide(self) -> i32 { return 2 }
}

class <A derives Base> Good derives A {
    pub fn fine(self) -> i32 { return self.n + self.begin() + A::begin(self) + Base::begin(self) }
    pub fn beyond(self) -> i32 { return self.only_wide() }
    pub fn Good(self, k: i32) { A::A(self, k) }
}

fn main() -> i32 {
    var g = Good<Wide>(1)
    return g.fine() + g.only_wide()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}param_base_body.k:24:46: error [R025E]: no member named 'only_wide' in 'Good'
// CHECK: {{.*}}param_base_body.k:25:36: error [SC351E]: a base initializer for the type-parameter base 'A' is not supported yet: its bound promises no constructor, so the base is built by its default constructor
