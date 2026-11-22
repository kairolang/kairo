// Covers partial moves out of a record parameter, a parameter forwarded through a
// panicking callee, try/catch/finally around a move, closures that consume the
// parameter, labelled breaks and short circuits. Every scenario balances.
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
    fn Pair(self, x: R, y: R) { self.a = x; self.b = y }
    @move fn Pair(self, o: Self) { self.a = o.a; self.b = o.b }
}
fn mayp(x: i32) panic -> i32 { if x > 0 { panic "boom" } return x }
fn both(p: Pair) { sink(p.a); sink(p.b) }
fn one(p: Pair) { sink(p.a) }
fn onec(p: Pair, c: bool) { if c { sink(p.b) } }
fn whole_or_part(p: Pair, c: bool) -> i32 { if c { var q = p; return 1 } sink(p.a); return 2 }
fn takeb(p: Pair) -> R { return p.b }

fn inner(p: R, x: i32) panic -> i32 { var v = mayp(x); sink(p); return v }
fn outer(p: R, x: i32) panic -> i32 { return inner(p, x) }
fn outer2(p: R, x: i32) panic -> i32 { var r = inner(p, x); return r + 1 }
fn outer3(p: R, x: i32, y: i32) panic -> i32 { if y > 0 { return inner(p, x) } return 0 }
fn fnl(p: R, x: i32) -> i32 {
    var acc = 0
    try { acc = mayp(x); sink(p) } catch { acc = -1 } finally { acc += 10 }
    return acc
}
fn fnl2(p: R, x: i32) -> i32 {
    var acc = 0
    try { sink(p); acc = mayp(x) } catch { acc = -1 } finally { acc += 10 }
    return acc
}
fn fnl3(p: R, x: i32) -> i32 {
    try { acc3 = mayp(x); return 1 } catch { sink(p); return 2 } finally { acc3 += 1 }
}
var acc3: i32 = 0
fn mk2(i: i32) -> Pair { return Pair(R(i), R(i + 1)) }
fn clmv(p: R) -> i32 {
    var f = fn () { sink(p) }
    f()
    return 1
}
fn clmv2(p: R, c: bool) -> i32 {
    var f = fn () { sink(p) }
    if c { f() }
    return 1
}
fn lbl(p: R, n: i32) -> i32 {
    var cnt = 0
    outer: for var i: i32 = 0; i < n; ++i {
        for var j: i32 = 0; j < n; ++j {
            if i + j == 3 { sink(p); break outer }
            cnt += 1
        }
    }
    return cnt
}
fn qop(p: R, o: R?) -> i32 { var z = o ?? p; return z.id }
fn qop2(p: R, o: i32?) -> i32 { var z = o ?? rd2(p); return z }
fn rd2(p: R) -> i32 { return p.id }

fn main() -> i32 {
    made = 0
    { var p = mk2(1); both(p) } chk("pp1")
    { var p = mk2(1); one(p) } chk("pp2")
    { var p = mk2(1); onec(p, true) } chk("pp3")
    { var p = mk2(1); onec(p, false) } chk("pp4")
    { var p = mk2(1); var v = whole_or_part(p, true) } chk("pp5")
    { var p = mk2(1); var v = whole_or_part(p, false) } chk("pp6")
    { var p = mk2(1); var q = takeb(p) } chk("pp7")
    { var a = R(1); try { outer(a, 1) } catch { } } chk("o1")
    { var a = R(1); try { outer(a, 0) } catch { } } chk("o2")
    { var a = R(1); try { outer2(a, 1) } catch { } } chk("o3")
    { var a = R(1); try { outer3(a, 1, 1) } catch { } } chk("o4")
    { var a = R(1); try { outer3(a, 1, 0) } catch { } } chk("o5")
    { var a = R(1); var v = fnl(a, 0) } chk("f1")
    { var a = R(1); var v = fnl(a, 1) } chk("f2")
    { var a = R(1); var v = fnl2(a, 1) } chk("f3")
    { var a = R(1); var v = fnl2(a, 0) } chk("f4")
    { var a = R(1); var v = fnl3(a, 0) } chk("f5")
    { var a = R(1); var v = fnl3(a, 1) } chk("f6")
    { var a = R(1); var v = clmv(a) } chk("c1")
    { var a = R(1); var v = clmv2(a, true) } chk("c2")
    { var a = R(1); var v = clmv2(a, false) } chk("c3")
    { var a = R(1); var v = lbl(a, 2) } chk("l1")
    { var a = R(1); var v = lbl(a, 5) } chk("l2")
    { var a = R(1); var v = qop(a, null) } chk("q1")
    { var a = R(1); var v = qop(a, R(3)) } chk("q2")
    { var a = R(1); var v = qop2(a, null) } chk("q3")
    { var a = R(1); var v = qop2(a, 4) } chk("q4")
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
