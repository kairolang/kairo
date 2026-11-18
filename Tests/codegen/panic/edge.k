// PanicLowering beyond §4.5a: a virtual method whose override panics with a
// smaller set (the override returns its base's result, as C++'s vtable
// needs), methods, `return f()` of a void function, a `try` in a loop whose
// arms `continue` and `break`, an expression `try` over two sites, a `try`
// nested in an arm, and a bare re-panic over two sites.
struct A { var v: i32 }
struct B { var v: i32 }

class Base {
    pub var k: i32
    fn Base(self) { self.k = 0 }
    fn Base(self, k: i32) { self.k = k }
    virtual fn get(self, n: i32) panic(A, B) -> i32 { if n < 0 { panic A { v: n } } return self.k + n }
    fn twice(self, n: i32) panic -> i32 { return self.get(n) + self.get(n) }
}
class Derived derives Base {
    fn Derived(self) { self.k = 100 }
    override fn get(self, n: i32) panic(B) -> i32 { if n < 0 { panic B { v: n } } return n }
}

fn ab(n: i32) panic(A, B) -> i32 {
    if n == 1 { panic A { v: 1 } }
    if n == 2 { panic B { v: 2 } }
    return n
}
var log: i32 = 0
fn vf(n: i32) panic(A) { if n == 1 { panic A { v: 1 } } log = log + 1 }
fn vcall(n: i32) panic(A) { return vf(n) }

fn loops() -> i32 {
    var hits = 0
    for var i: i32 = 0; i < 6; ++i {
        try { var x = ab(i) + ab(i + 10)  hits = hits + x } catch e: A { continue } catch e: B { break }
    }
    return hits
}
fn multi_expr(n: i32) -> i32 {
    return try ab(n) + ab(n + 1) catch e: A => 100 + e.v catch e: B => 200 + e.v
}
fn nested_arm(n: i32) panic -> i32 {
    try { return ab(n) } catch e: A { try { return ab(2) } catch f: B { return f.v + e.v * 10 } }
}
fn repanic_multi(n: i32) panic -> i32 {
    try { var x = ab(n) + ab(n + 1)  return x } catch e { panic e }
}

fn main() -> i32 {
    var d = Derived()
    var p: *Base = &d
    if (try p->get(5) catch => 0) != 5 { return 1 }
    if (try p->get(-1) catch e: B => e.v catch => 0) != -1 { return 2 }
    if (try d.twice(3) catch => 0) != 6 { return 3 }
    var bb = Base(10)
    if (try bb.get(-7) catch e: A => e.v catch => 0) != -7 { return 4 }
    try { vcall(0) } catch { return 5 }
    try { vcall(1) } catch e: A { log = log + 10 }
    if log != 11 { return 6 }
    if loops() != 10 { return 7 }
    if multi_expr(1) != 101 { return 8 }
    if multi_expr(5) != 11 { return 9 }
    if multi_expr(2) != 202 { return 14 }
    if (try nested_arm(1) catch => 0) != 12 { return 10 }
    if (try repanic_multi(1) catch e: A => e.v catch => 0) != 1 { return 11 }
    if (try repanic_multi(2) catch e: B => e.v catch => 0) != 2 { return 12 }
    if (try repanic_multi(5) catch => 0) != 11 { return 13 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
