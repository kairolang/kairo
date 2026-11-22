// Covers the argument forms of a call whose parameter is a destructive class: if
// expressions, results assigned back to the argument local, panicking calls in
// other arguments, nested calls, conditionally moved locals, fields, nullables,
// methods, static methods and generic functions. Every scenario balances.
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
class Pair { var a: R; var b: R
    fn Pair(self, x: i32, y: i32) { self.a = R(x); self.b = R(y) }
    @move fn Pair(self, o: Self) { self.a = o.a; self.b = o.b }
}
class Holder { var r: R
    fn Holder(self, x: R) { self.r = x }
    @move fn Holder(self, o: Self) { self.r = o.r }
}
class Maybe { var r: R
    fn Maybe(self, x: R, keep: bool) { if keep { self.r = x } else { self.r = R(70) } }
    @move fn Maybe(self, o: Self) { self.r = o.r }
}
class Sub { var r: R
    fn Sub(self, x: R) { self.r = x }
    @move fn Sub(self, o: Self) { self.r = o.r }
    fn put(self, x: R) { self.r = x }
    fn eat(self, x: R) { sink(x) }
    static fn mk(x: R) -> Sub { return Sub(x) }
    static fn drop(x: R) { }
    fn both(self, x: R, y: R) -> i32 { return x.id + y.id }
}
fn two(a: R, b: R) -> i32 { return a.id + b.id }
fn pick(c: bool, a: R, b: R) -> R { if c { return a } return b }
fn pass(r: R) -> R { return r }
fn mayp(x: i32) panic -> i32 { if x > 0 { panic "boom" } return x }
fn withpan(r: R, x: i32) panic -> i32 { sink(r); return mayp(x) }
fn rdp(r: R, x: i32) panic -> i32 { return r.id + mayp(x) }
fn two_p(a: R, x: i32) panic -> i32 { sink(a); return mayp(x) }
fn tup(p: R, q: i32) -> i32 { sink(p); return q }
fn ro(r: R) -> i32 { return r.id }
fn cnd(r: R, b: bool) { if b { sink(r) } }

fn <T> gen(x: T) -> T { return x }
fn <T> gdrop(x: T) { }

fn main() -> i32 {
    { var a = R(1); var b = R(2); var c = true; two(if (c) => a else => b, R(1)) } chk("ifexpr")
    { var a = R(1); var b = R(2); var c = false; sink(if (c) => a else => b) } chk("ifexpr2")
    { var a = R(1); var b = R(2); var q = pick(true, a, b) } chk("pick")
    { var a = R(1); var b = R(2); var q = pick(false, a, b) } chk("pick2")
    { var a = R(1); a = pass(a) } chk("selfasg")
    { var a = R(1); a = pass(pass(a)) } chk("selfasg2")
    { var a = R(1); var c = true; a = if (c) => pass(a) else => R(5) } chk("selfasg3")
    { var a = R(1); var c = false; a = if (c) => pass(a) else => a } chk("selfasg4")
    { var a = R(1); for var i: i32 = 0; i < 3; ++i { a = pass(a) } } chk("selfasgloop")
    { var a = R(1); for var i: i32 = 0; i < 3; ++i { a = pass(pass(a)) } } chk("selfasgloop2")
    { var a = R(1); var b = R(2); a = pick(true, a, b) } chk("pickself")
    { var a = R(1); var b = R(2); a = pick(false, b, a) } chk("pickself2")
    { var a = R(1); var b = R(2); b = pick(true, a, b) } chk("pickself3")
    { var a = R(1); try { withpan(a, 0) } catch { } } chk("wp0")
    { var a = R(1); try { withpan(a, 1) } catch { } } chk("wp1")
    { var a = R(1); try { rdp(a, 1) } catch { } } chk("rdp1")
    { var a = R(1); try { rdp(a, 0) } catch { } } chk("rdp0")
    { var a = R(1); try { sink(a); mayp(1) } catch { } } chk("sp")
    // panic in another arg
    { var a = R(1); try { tup(a, mayp(1)) } catch { } } chk("argpan1")
    { var a = R(1); try { tup(a, mayp(0)) } catch { } } chk("argpan0")
    { var a = R(1); var b = R(2); try { two(a, R(mayp(1))) } catch { } } chk("argpan2")
    { var a = R(1); try { two(R(mayp(1)), a) } catch { } } chk("argpan3")
    { var a = R(1); try { two(R(mayp(0) + 7), a) } catch { } } chk("argpan4")
    { var a = R(1); try { tup(a, mayp(0)) } catch { } } chk("argpan5")
    { var a = R(1); var b = R(2); try { two(a, b) mayp(1) } catch { } } chk("two")
    // return / break / continue inside arguments
    for var i: i32 = 0; i < 3; ++i { var a = R(1); tup(a, if (i == 1) => 7 else => 0) chk("loopif") }
    for var i: i32 = 0; i < 3; ++i { var a = R(1); var z = tup(a, if (i == 1) => 0 else => 3) chk("loopif2") }
    // nested
    { var a = R(1); var b = ro(pass(pass(a))) } chk("nest1")
    { var a = R(1); sink(pass(pass(pass(a)))) } chk("nest2")
    { var a = R(1); var b = pass(pass(a)); var c = pass(b) } chk("nest3")
    // conditionally moved before call
    for var i: i32 = 0; i < 2; ++i { var a = R(1); if i == 0 { sink(a); a = R(2) } sink(a) chk("condmv") }
    for var i: i32 = 0; i < 2; ++i { var a = R(1); if i == 0 { sink(a); a = R(2) } cnd(a, i == 1) chk("condmv2") }
    // fields etc
    { var p = Pair(1, 2); sink(p.a) sink(p.b) } chk("field")
    { var p = Pair(1, 2); sink(p.a) p.a = R(5) sink(p.a) } chk("field2")
    { var p = Pair(1, 2); var q = pass(p.a) } chk("field3")
    { var p = Pair(1, 2); p.a = pass(p.a) } chk("field4")
    { var p = Pair(1, 2); p.a = pass(pass(p.b)); p.b = R(3) } chk("field5")
    { var h = Holder(R(1)) } chk("hold1")
    { var a = R(1); var h = Holder(a) } chk("hold2")
    { var a = R(1); var h = Maybe(a, true) } chk("maybe1")
    { var a = R(1); var h = Maybe(a, false) } chk("maybe2")
    { var a: R? = R(1); if a != null { sink(a) } } chk("nullable")
    { var a: R? = R(1); sink(a ?? R(2)) } chk("nullcoal")
    { var a: R? = null; sink(a ?? R(2)) } chk("nullcoal2")
    { var a = R(1); var b = (a); sink(b) } chk("paren")
    { var a = R(1); sink((a)) } chk("paren2")
    // methods
    { var s = Sub(R(1)); var a = R(2); s.put(a) } chk("m1")
    { var s = Sub(R(1)); var a = R(2); s.eat(a) } chk("m2")
    { var a = R(2); var s = Sub::mk(a) } chk("m3")
    { var a = R(2); Sub::drop(a) } chk("m4")
    { var s = Sub(R(1)); var a = R(2); var b = R(3); s.both(a, b) } chk("m5")
    // generics
    { var a = R(1); var b = gen(a) } chk("g1")
    { var a = R(1); gdrop(a) } chk("g2")
    { var a = R(1); var b = gen(pass(a)) } chk("g3")
    { var v: [R] = [R(1), R(2)]; var w = pass2(v) } chk("g4")
    println(f"fails {fails}")
    return fails
}
fn pass2(v: [R]) -> [R] { return v }

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
