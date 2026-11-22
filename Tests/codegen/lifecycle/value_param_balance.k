// By-value parameters of a destructive class through the argument forms
// and exits that decide who ends the object (ownership.mdx, Moved-From
// State; functions.mdx, Parameters): an argument beside one that panics,
// named and defaulted arguments, values moved out of a field and out of a
// nullable, a parameter passed on, a panic in the callee, a
// `try` in the callee, generic functions and containers, `fn` values,
// closures, virtual calls and an interface's requirement. R counts live
// objects: every value made is released exactly once, with destructive
// moves and without (-fno-destructive-moves).
import std::io::println

var made: i32 = 0
var released: i32 = 0
var fails: i32 = 0

class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id; made += 1 }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) {
        if self.id != 0 {
            released += 1
            self.id = 0
        }
    }
}

fn chk(const name: string) {
    if made != released {
        println(f"FAIL {name}: made {made} released {released}")
        fails += 1
    }

    made = 0
    released = 0
}

fn may(x: i32) panic -> i32 {
    if x > 0 { panic "boom" }
    return x
}

fn keep(r: R) -> i32 { return r.id }
fn sink(r: R) { }
fn pass(r: R) -> R { return r }
fn fwd(r: R) { sink(r) }
fn maybe(r: R, yes: bool) { if yes { sink(r) } }
fn two(r: R, x: i32) -> i32 { return r.id + x }
fn two_r(x: i32, r: R) -> i32 { return r.id + x }
fn fwd2(r: R, x: i32) -> i32 { sink(r); return x }
fn dflt(r: R, x: i32 = 7) -> i32 { sink(r); return x }

// The callee itself panics, before or after it moved the value on.
fn late(r: R, x: i32) panic -> i32 {
    var n = may(x)
    sink(r)
    return n
}
fn early(r: R, x: i32) panic -> i32 {
    sink(r)
    return may(x)
}
fn caught(r: R, x: i32) -> i32 {
    try {
        var n = may(x)
        sink(r)
        return n
    } catch {
        return -1
    }
}

// An argument beside one that panics, in both positions.
fn p_after(x: i32) panic { var a = R(1); fwd2(a, may(x)) }
fn p_before(x: i32) panic { var a = R(1); two_r(may(x), a) }
fn p_prvalue(x: i32) panic { fwd2(R(1), may(x)) }
fn p_keep(x: i32) panic { var a = R(1); two(a, may(x)) }
fn p_late(x: i32) panic { var a = R(1); late(a, x); late(R(2), x) }
fn p_early(x: i32) panic { var a = R(1); early(a, x); early(R(2), x) }

struct Box { var r: R }
class Own {
    var r: R
    var rs: [R]
    fn Own(self) { self.r = R(10); self.rs = [] }
    fn give(self) { fwd(self.r); self.r = R(11) }
    fn give_keep(self) -> i32 {
        var n = keep(self.r)
        self.r = R(12)
        return n
    }
}

fn from_field() { var b = Box { r: R(1) }; fwd(b.r) }
fn from_field_keep() { var b = Box { r: R(1) }; keep(b.r) }
fn from_elem() {
    var v: [R] = []
    v.push(R(1))
    v.push(R(2))
    fwd(v.pop() ?? R(9))
    keep(v.pop() ?? R(8))
}
fn param_on(r: R) { fwd(r) }
fn param_keep(r: R) -> i32 { return keep(r) }
fn param_maybe(r: R, yes: bool) { maybe(r, yes) }

fn <T> gpass(x: T) -> T { return x }
fn <T> gsink(x: T) { }
fn <T> gpush(v: *[T], x: T) { v->push(x) }
class <T> Stack {
    var items: [T]
    fn Stack(self) { self.items = [] }
    fn put(self, v: T) { self.items.push(v) }
    fn drop(self, v: T) { }
    fn put_if(self, v: T, yes: bool) { if yes { self.items.push(v) } }
}

class Base {
    fn Base(self) { }
    virtual fn take(self, r: R) -> i32 { return r.id }
}
class Deep derives Base {
    fn Deep(self) { Base::Base(self) }
    override fn take(self, r: R) -> i32 {
        sink(r)
        return 0
    }
}
fn through(b: *Base, r: R) -> i32 { return b->take(r) }

interface Taker {
    fn take_it(self, r: R) -> i32
}
class Reads impl Taker {
    fn Reads(self) { }
    fn take_it(self, r: R) -> i32 { return r.id }
}
class Stores impl Taker {
    var kept: [R]
    fn Stores(self) { self.kept = [] }
    fn take_it(self, r: R) -> i32 {
        self.kept.push(r)
        return 0
    }
}
fn <T impl Taker> feed(t: *T, r: R) -> i32 { return t->take_it(r) }

fn main() -> i32 {
    { var a = R(1); keep(a); keep(R(2)) }
    chk("keep")
    { var a = R(1); fwd(a); fwd(R(2)); var b = pass(pass(R(3))) }
    chk("moved on")
    { var a = R(1); maybe(a, true); maybe(R(2), true); var b = R(3); maybe(b, false); maybe(R(4), false) }
    chk("maybe")
    { var a = R(1); two(a, 1); two_r(2, R(2)); fwd2(R(3), 3) }
    chk("two")
    { var a = R(1); dflt(a); dflt(R(2), 3); dflt(x: 4, r: R(3)) }
    chk("default and named")

    try { p_after(1) } catch { }
    chk("panic after the argument")
    try { p_after(0) } catch { }
    chk("no panic after the argument")
    try { p_before(1) } catch { }
    chk("panic before the argument")
    try { p_before(0) } catch { }
    chk("no panic before the argument")
    try { p_prvalue(1) } catch { }
    chk("panic beside a prvalue")
    try { p_prvalue(0) } catch { }
    chk("no panic beside a prvalue")
    try { p_keep(1) } catch { }
    chk("panic beside a kept argument")
    try { p_late(1) } catch { }
    chk("callee panics before its move")
    try { p_late(0) } catch { }
    chk("callee does not panic before its move")
    try { p_early(1) } catch { }
    chk("callee panics after its move")
    { var a = R(1); caught(a, 1); caught(R(2), 0) }
    chk("callee catches")

    from_field()
    chk("from a field")
    from_field_keep()
    chk("from a field, kept")
    from_elem()
    chk("from an element")
    { var o = Own(); o.give(); o.give_keep() }
    chk("from a field of self")
    { var a = R(1); param_on(a); param_keep(R(2)); param_maybe(R(3), true); param_maybe(R(4), false) }
    chk("a parameter passed on")

    { var a = R(1); var b = gpass(a); var c = gpass<R>(R(2)); gsink(R(3)); var d = R(4); gsink(d) }
    chk("generic functions")
    { var v: [R] = []; var a = R(1); gpush(&v, a); gpush(&v, R(2)); v.push(R(3)); v.insert(0, R(4)) }
    chk("vector")
    {
        var s = Stack<R>()
        var a = R(1)
        s.put(a)
        s.put(R(2))
        s.drop(R(3))
        s.put_if(R(4), true)
        s.put_if(R(5), false)
        var i = Stack<i32>()
        i.put(1)
        i.put_if(2, false)
    }
    chk("generic class")

    {
        var f: fn(R) -> i32 = keep
        f(R(1))
        var a = R(2)
        f(a)
        var g: fn(R) = fwd
        g(R(3))
        var h: fn(R) -> R = gpass<R>
        var k = h(R(4))
        var cl = fn (r: R) -> i32 { return r.id }
        cl(R(5))
        var cm = fn (r: R) { sink(r) }
        cm(R(6))
        var b = R(7)
        cm(b)
    }
    chk("fn values and closures")

    {
        var b = Base()
        var d = Deep()
        var a = R(1)
        b.take(a)
        b.take(R(2))
        d.take(R(3))
        through(&d, R(4))
        var c = R(5)
        through(&b, c)
    }
    chk("virtual")

    {
        var r = Reads()
        var s = Stores()
        var a = R(1)
        feed(&r, a)
        feed(&r, R(2))
        feed(&s, R(3))
        var b = R(4)
        feed(&s, b)
        r.take_it(R(5))
        s.take_it(R(6))
    }
    chk("interface")

    if fails == 0 { println("balanced") }
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d %t.o2.d
// RUN: rm -f %t.exe %t.off.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK-NOT: FAIL
// CHECK: balanced
