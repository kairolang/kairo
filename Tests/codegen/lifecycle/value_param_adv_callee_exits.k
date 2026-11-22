// Covers a by-value parameter of a destructive class across every way the callee body can
// leave it: break and continue around a move, match arms, short circuits, try and
// catch around a panicking call, reassignment, recursion, closures and defaults.
// Each scenario ends with a balance check of constructed against destroyed objects.
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
// callee exits
fn brk(p: R, n: i32) -> i32 {
    for var i: i32 = 0; i < n; ++i {
        if i == 3 { sink(p); break }
    }
    return n
}
fn brk2(p: R, n: i32) -> i32 {
    outer: for var i: i32 = 0; i < 3; ++i {
        for var j: i32 = 0; j < n; ++j {
            if j == 1 { sink(p); break outer }
            continue outer
        }
    }
    return n
}
fn zero(p: R, n: i32) {
    for var i: i32 = 0; i < n; ++i { if i == 0 { sink(p); break } }
}
fn wh(p: R, n: i32) -> i32 {
    var k = 0
    while k < n { k += 1; if k == 2 { var t = p; return k } }
    return k
}
fn mt(p: R, k: i32) -> i32 {
    match k {
        case 0 { sink(p) }
        case 1 { return 5 }
        case 2 { var x = p; return x.id }
        default { }
    }
    return 0
}
fn sc(p: R, b: bool) -> bool { return b && rd(p) > 0 }
fn sc2(p: R, b: bool) -> bool { return b || rd(p) > 0 }
fn sc3(p: R, b: bool) -> i32 { var x = 0; if b && (rd(p) > 0) { x = 1 }; return x }
fn mayp(x: i32) panic -> i32 { if x > 0 { panic "boom" } return x }
fn tr1(p: R, x: i32) -> i32 {
    try { var v = mayp(x); sink(p); return v } catch { return -1 }
}
fn tr2(p: R, x: i32) -> i32 {
    try { sink(p); var v = mayp(x); return v } catch { return -2 }
}
fn tr3(p: R, x: i32) -> i32 {
    try { var v = mayp(x); sink(p); return v } catch { sink(p); return -3 }
}
fn pan_before(p: R, x: i32) panic -> i32 { var v = mayp(x); sink(p); return v }
fn pan_after(p: R, x: i32) panic -> i32 { sink(p); var v = mayp(x); return v }
fn reasg(p: R) -> i32 { sink(p); p = R(9); return p.id }
fn reasg2(p: R) -> i32 { p = R(9); sink(p); return 1 }
fn reasg3(p: R, b: bool) -> i32 { if b { sink(p) } p = R(8); return p.id }
fn addr(p: R) -> i32 { var *q = &p; return q->id }
fn ref_ret(p: R) -> R { return p }
fn ret_drop(p: R, b: bool) -> R { if b { return p } return R(77) }
fn pmove(p: R) { sink(p); sink(R(3)) }
fn rec(p: R, n: i32) -> i32 { if n == 0 { sink(p); return 0 } return rec(p, n - 1) + 1 }
fn mut_a(p: R, n: i32) -> i32 { if n == 0 { return 0 } return mut_b(p, n - 1) }
fn mut_b(p: R, n: i32) -> i32 { if n == 0 { sink(p); return 1 } return mut_a(p, n - 1) }
fn exprb(r: R) -> R = r
fn expr_rd(r: R) -> i32 = r.id
fn dflt(a: R, b: i32 = 5) -> i32 { sink(a); return b }
fn named(a: R, b: R) -> i32 { sink(b); return a.id }
fn nul(p: R?) -> i32 { if p != null { return 1 } return 0 }
fn cl(p: R) -> i32 {
    var f = fn () -> i32 { return p.id }
    return f()
}
fn cl2(p: R) -> i32 {
    var f = fn () { sink(p) }
    f()
    return 1
}
fn qq(p: R, o: R?) -> i32 { var z = o ?? p; return z.id }

fn main() -> i32 {
    { var a = R(1); brk(a, 5) } chk("brk1")
    { var a = R(1); brk(a, 2) } chk("brk2")
    { var a = R(1); brk2(a, 5) } chk("brk2b")
    { var a = R(1); brk2(a, 1) } chk("brk2c")
    { var a = R(1); zero(a, 0) } chk("zero0")
    { var a = R(1); zero(a, 1) } chk("zero1")
    { var a = R(1); wh(a, 1) } chk("wh1")
    { var a = R(1); wh(a, 5) } chk("wh5")
    for var k: i32 = 0; k < 4; ++k { var a = R(1); mt(a, k) chk("mt") }
    { var a = R(1); sc(a, true) ; var a1 = R(1); sc(a1, false) } chk("sc")
    { var a = R(1); sc2(a, true) ; var a1 = R(1); sc2(a1, false) } chk("sc2")
    { var a = R(1); sc3(a, true) ; var a1 = R(1); sc3(a1, false) } chk("sc3")
    { var a = R(1); tr1(a, 0) ; var a1 = R(1); tr1(a1, 1) } chk("tr1")
    { var a = R(1); tr2(a, 0) } chk("tr2a")
    { var a = R(1); tr2(a, 1) } chk("tr2b")
    { var a = R(1); tr3(a, 0) } chk("tr3a")
    { var a = R(1); tr3(a, 1) } chk("tr3b")
    { var a = R(1); try { pan_before(a, 1) } catch { } } chk("panb")
    { var a = R(1); try { pan_before(a, 0) } catch { } } chk("panb0")
    { var a = R(1); try { pan_after(a, 1) } catch { } } chk("pana")
    { var a = R(1); try { pan_after(a, 0) } catch { } } chk("pana0")
    { var a = R(1); reasg(a) } chk("reasg")
    { var a = R(1); reasg2(a) } chk("reasg2")
    { var a = R(1); reasg3(a, true) ; var a1 = R(1); reasg3(a1, false) } chk("reasg3")
    { var a = R(1); addr(a) } chk("addr")
    { var a = R(1); var b = ref_ret(a) } chk("ref_ret")
    { var a = R(1); var b = ret_drop(a, true) } chk("ret_drop1")
    { var a = R(1); var b = ret_drop(a, false) } chk("ret_drop2")
    { var a = R(1); pmove(a) } chk("pmove")
    { var a = R(1); rec(a, 4) } chk("rec")
    { var a = R(1); mut_a(a, 5) ; var a1 = R(1); mut_a(a1, 4) } chk("mut")
    { var a = R(1); var b = exprb(a) } chk("exprb")
    { var a = R(1); expr_rd(a) } chk("expr_rd")
    { var a = R(1); dflt(a) ; var a1 = R(1); dflt(a1, 3) } chk("dflt")
    { var a = R(1); var b = R(2); named(b: a, a: b) } chk("named")
    { var a = R(1); nul(a) } chk("nul")
    { var a = R(1); cl(a) } chk("cl")
    { var a = R(1); cl2(a) } chk("cl2")
    { var a = R(1); qq(a, null) ; var a1 = R(1); qq(a1, R(4)) } chk("qq")
    { sink(R(1)) sink(mkr(2)) rd(mkr(3)) var q = exprb(exprb(mkr(5))) } chk("temps")
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
