// A derived class's method joins the base's overloads of the same name
// instead of hiding them: a call picks among both by its argument, through
// a generic base's instance and through two bases. By what the calls
// return; no emitted text is pinned.

class A {
    virtual fn k(self) -> i32 { return 1 }
    fn f(self, x: i32) -> i32 { return 10 }
    fn A(self) { }
    virtual fn op finally(self) { }
}

class D derives A {
    override fn k(self) -> i32 { return 2 }
    fn f(self, x: f64) -> i32 { return 20 }
    fn D(self) { }
    override fn op finally(self) { }
}

class <T> G {
    fn g(self, t: T) -> i32 { return 100 }
}

class GD derives G<i32> {
    fn g(self, t: f64) -> i32 { return 200 }
}

class L { fn m(self, x: i32) -> i32 { return 1000 } }
class R { fn m(self, x: bool) -> i32 { return 2000 } }
class LR derives L, R {
    fn m(self, x: f64) -> i32 { return 3000 }
}

fn main() -> i32 {
    var d  = D()
    var g  = GD()
    var lr = LR()
    var i: i32 = 1
    var x: f64 = 1.0
    if d.k() != 2 { return 1 }
    if d.f(i) != 10 { return 2 }
    if d.f(x) != 20 { return 3 }
    if g.g(i) != 100 { return 4 }
    if g.g(x) != 200 { return 5 }
    if lr.m(i) != 1000 { return 6 }
    if lr.m(true) != 2000 { return 7 }
    if lr.m(x) != 3000 { return 8 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
