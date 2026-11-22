// Covers constructors with a base-class initializer, nested classes, interface and virtual
// dispatch, calls through fn values and default or named arguments with a
// destructive by-value parameter. Every scenario balances.
import std::io::println
var made: i32 = 0
var released: i32 = 0
var fails: i32 = 0
class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id; made += 1 }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) {
        if self.id != 0 { released += 1; self.id = 0 }
    }
}
fn chk(const name: string) {
    if made != released { println(f"FAIL {name}: made {made} released {released}"); fails += 1 }
    made = 0
    released = 0
}
fn mkr(i: i32) -> R { return R(i) }
fn sink(r: R) { }
fn rd(r: R) -> i32 { return r.id }
class Base { var r: R
    fn Base(self, x: R) { self.r = x }
    @move fn Base(self, o: Self) { self.r = o.r }
}
class Derived derives Base { var q: R
    fn Derived(self, x: R, y: R, keep: bool) { Base::Base(self, x); if keep { self.q = y } else { self.q = R(71) } }
    @move fn Derived(self, o: Self) { Base::Base(self, o.r); self.q = o.q }
}
class Outer { var r: R
    class Inner { var z: R
        fn Inner(self, x: R) { self.z = x }
        @move fn Inner(self, o: Self) { self.z = o.z }
        fn take(self, x: R) { self.z = x }
    }
    fn Outer(self, x: R) { self.r = x }
    @move fn Outer(self, o: Self) { self.r = o.r }
}
interface I { fn m(self, r: R) -> i32 }
class X impl I {
    var k: i32 = 0
    fn X(self) { }
    fn m(self, r: R) -> i32 { return r.id }
}
class Y impl I {
    var k: i32 = 0
    fn Y(self) { }
    fn m(self, r: R) -> i32 { sink(r); return 2 }
}
class V { 
    var k: i32 = 0
    fn V(self) { }
    virtual fn vm(self, r: R) -> i32 { return r.id }
}
class W derives V {
    fn W(self) { V::V(self) }
    override fn vm(self, r: R) -> i32 { sink(r); return 3 }
}
fn <T impl I> call_i(i: *T, r: R) -> i32 { return i->m(r) }
fn call_f(f: fn(R) -> i32, r: R) -> i32 { return f(r) }
fn call_f2(f: fn(R) -> i32, r: R) -> i32 { var z = f(r); return z }
fn cfd(r: R) -> i32 { sink(r); return 4 }
fn mk_d(x: R, y: R, keep: bool) -> Derived { return Derived(x, y, keep) }
fn dflt(a: R, b: R = R(9)) -> i32 { sink(a); return b.id }
fn pnamed(a: R, c: R) -> i32 { return a.id * 10 + c.id }

fn main() -> i32 {
    made = 0
    { var a = R(1); var b = R(2); var d = Derived(a, b, true) } chk("c1")
    { var a = R(1); var b = R(2); var d = Derived(a, b, false) } chk("c2")
    { var a = R(1); var b = R(2); var d = mk_d(a, b, true) } chk("c3")
    { var a = R(1); var b = R(2); var d = mk_d(a, b, false) } chk("c4")
    { var a = R(1); var o = Outer(a); var i = Outer::Inner(R(5)); var b = R(2); i.take(b) } chk("c5")
    { var x = X(); var a = R(1); var v = call_i(&x, a) } chk("i1")
    { var y = Y(); var a = R(1); var v = y.m(a) } chk("i2")
    { var y = Y(); var a = R(1); var v = call_i(&y, a) } chk("i3")
    { var w = W(); var a = R(1); var v = w.vm(a) } chk("v1")
    { var w = W(); var a = R(1); var pv: *V = &w; var v = pv->vm(a) } chk("v2")
    { var a = R(1); var v = call_f(cfd, a) } chk("f1")
    { var a = R(1); var v = call_f2(fn (r: R) -> i32 { return r.id }, a) } chk("f2")
    { var a = R(1); var f = cfd; var v = f(a) } chk("f3")
    { var a = R(1); var v = dflt(a) } chk("d1")
    { var a = R(1); var b = R(2); var v = dflt(a, b) } chk("d2")
    { var a = R(1); var b = R(2); var v = pnamed(c: a, a: b); if v != 21 { println(f"FAIL named {v}"); fails += 1 } } chk("d3")
    println(f"fails {fails}")
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --match-full-lines
// CHECK-NOT: FAIL
// CHECK: fails 0
