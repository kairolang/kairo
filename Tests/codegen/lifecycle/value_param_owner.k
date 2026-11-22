// A by-value parameter of a destructive class (ownership.mdx, Moved-From
// State) is the caller's object, passed as `C&&`, and a moved-from object
// of such a class is never destroyed. So a destructor that counts itself
// runs once per object ever alive, whichever way the value goes: read by
// the callee and destroyed by the caller, moved on by the callee on every
// path, or moved on some paths and destroyed by the callee on the others.
import std::io::println

var dtors: i32 = 0
var fails: i32 = 0

class C {
    var id: i32 = 0
    fn C(self, id: i32) { self.id = id }
    @move fn C(self, other: Self) { self.id = other.id }
    fn op finally(self) { dtors += 1 }
}

fn check(const name: string, want: i32) {
    if dtors != want {
        println(f"FAIL {name}: {dtors} destructor calls, want {want}")
        fails += 1
    }

    dtors = 0
}

fn mk(i: i32) -> C { return C(i) }

// The callee only reads: the caller destroys what it passed.
fn eat(c: C) { }
fn rd(c: C) -> i32 { return c.id }
fn two(a: C, b: C) -> i32 { return a.id + b.id }

// The callee moves the value on at every exit.
fn fwd(c: C) { eat(c) }
fn ret(c: C) -> C { return c }
fn keep_one(a: C, b: C) -> C { return a }
fn local(c: C) -> i32 {
    var mine = c
    return mine.id
}
fn rec(c: C, n: i32) {
    if n == 0 {
        eat(c)
        return
    }

    rec(c, n - 1)
}

// The callee moves it on some paths and destroys the value on the others.
fn cond(c: C, b: bool) { if b { eat(c) } }
fn early(c: C, b: bool) -> i32 {
    if b { return 1 }
    eat(c)
    return 2
}
fn looped(c: C, n: i32) -> i32 {
    for var i: i32 = 0; i < n; ++i {
        if i == 2 {
            eat(c)
            return i
        }
    }

    return -1
}
fn matched(c: C, k: i32) -> i32 {
    match k {
        case 0 { eat(c) }
        case 1 { return 1 }
        default { var t = c }
    }

    return 0
}

class Holder {
    var c: C
    fn Holder(self, c: C) { self.c = c }
}

class Pair {
    var a: C
    var b: C
    var n: i32 = 0
    fn Pair(self, a: C, b: C, n: i32) {
        self.a = a
        self.b = b
        self.n = n
    }
}

class Outer {
    var h: Holder
    fn Outer(self, c: C) { self.h = Holder(c) }
}

class Bag {
    var items: [C]
    fn Bag(self) { self.items = [] }
    fn add(self, c: C) { self.items.push(c) }
    fn add_if(self, c: C, yes: bool) -> bool {
        if yes {
            self.items.push(c)
            return true
        }

        return false
    }
    fn peek(const self, c: C) -> i32 { return c.id }
}

fn s_eat() { var a = C(1); eat(a) }
fn s_eat_pr() { eat(C(1)) }
fn s_rd() { var a = C(1); rd(a); rd(mk(2)) }
fn s_two() { var a = C(1); two(a, C(2)) }
fn s_fwd() { var a = C(1); fwd(a); fwd(C(2)) }
fn s_ret() { var a = C(1); var r = ret(a); var q = ret(C(2)) }
fn s_keep() { var a = C(1); var k = keep_one(a, C(2)) }
fn s_local() { var a = C(1); local(a); local(mk(2)) }
fn s_rec() { var a = C(1); rec(a, 3); rec(C(2), 0) }
fn s_cond(b: bool) { var a = C(1); cond(a, b); cond(mk(2), b) }
fn s_early(b: bool) { var a = C(1); early(a, b); early(C(2), b) }
fn s_looped(n: i32) { var a = C(1); looped(a, n) }
fn s_matched(k: i32) { var a = C(1); matched(a, k); matched(C(2), k) }
fn s_chain() { var a = C(1); fwd(ret(ret(a))) }
fn s_field() { var a = C(1); var h = Holder(a); var g = Holder(C(2)) }
fn s_pair() { var a = C(1); var p = Pair(a, C(2), 3) }
fn s_outer() { var a = C(1); var o = Outer(a); var q = Outer(mk(2)) }
fn s_push() { var a = C(1); var v: [C] = []; v.push(a); v.push(C(2)); v.push(mk(3)) }
fn s_bag() {
    var b = Bag()
    var a = C(1)
    b.add(a)
    b.add(C(2))
    b.add_if(C(3), true)
    b.add_if(C(4), false)
    b.peek(C(5))
}
fn s_param(c: C) { fwd(c) }
fn s_param_call() { var a = C(1); s_param(a) }

fn main() -> i32 {
    s_eat(); check("eat local", 1)
    s_eat_pr(); check("eat prvalue", 1)
    s_rd(); check("rd", 2)
    s_two(); check("two", 2)
    s_fwd(); check("fwd", 2)
    s_ret(); check("ret", 2)
    s_keep(); check("keep_one", 2)
    s_local(); check("local", 2)
    s_rec(); check("rec", 2)
    s_cond(true); check("cond true", 2)
    s_cond(false); check("cond false", 2)
    s_early(true); check("early true", 2)
    s_early(false); check("early false", 2)
    s_looped(5); check("looped moved", 1)
    s_looped(1); check("looped kept", 1)
    s_matched(0); check("matched 0", 2)
    s_matched(1); check("matched 1", 2)
    s_matched(2); check("matched 2", 2)
    s_chain(); check("chain", 1)
    s_field(); check("field", 2)
    s_pair(); check("pair", 2)
    s_outer(); check("outer", 2)
    s_push(); check("push", 3)
    s_bag(); check("bag", 5)
    s_param_call(); check("param forwarded", 1)
    if fails == 0 { println("every object destroyed once") }
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK-NOT: FAIL
// CHECK: every object destroyed once
