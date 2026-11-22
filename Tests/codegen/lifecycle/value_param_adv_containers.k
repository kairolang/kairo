// Covers by-value parameters of string, vector, map and record types that hold a
// destructive class, passed on, dropped, assigned back or pushed into a vector
// through a pointer on some paths only. Every scenario balances.
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
class VH { var items: [R]
    fn VH(self) { self.items = [] }
    @move fn VH(self, o: Self) { self.items = o.items }
    fn add(self, r: R) { self.items.push(r) }
    fn addv(self, v: [R]) { for var i: i32 = 0; i < 1; ++i { } }
}
fn vsink(v: [R]) { }
fn vpass(v: [R]) -> [R] { return v }
fn vcond(v: [R], b: bool) { if b { vsink(v) } }
fn ssink(s: string) { }
fn spass(s: string) -> string { return s }
fn scond(s: string, b: bool) -> i32 { if b { ssink(s) } return 1 }
fn slen(s: string) -> usize { return s.size() }
fn dsink(d: {string: R}) { }
fn dpass(d: {string: R}) -> {string: R} { return d }
fn ssv(v: [string]) { }
fn vh(v: VH) { }
fn vhp(v: VH) -> VH { return v }
fn vadd(v: VH, r: R) { v.add(r) }
fn push_into(v: *[R], r: R) { v->push(r) }
fn push_if(v: *[R], r: R, b: bool) { if b { v->push(r) } }
fn push_loop(v: *[R], r: R, n: i32) { for var i: i32 = 0; i < n; ++i { if i == 1 { v->push(r); break } } }

fn main() -> i32 {
    made = 0
    { var v: [R] = [R(1), R(2)]; vsink(v) } chk("v1")
    { var v: [R] = [R(1), R(2)]; var w = vpass(v) } chk("v2")
    { var v: [R] = [R(1), R(2)]; vcond(v, true) } chk("v3")
    { var v: [R] = [R(1), R(2)]; vcond(v, false) } chk("v4")
    { var v: [R] = [R(1), R(2)]; v = vpass(v) } chk("v5")
    { var v: [R] = [R(1), R(2)]; v = vpass(vpass(v)) } chk("v6")
    { var s = "abc"; ssink(s) } chk("s1")
    { var s = "abc"; s = spass(s) ; var n = slen(s) } chk("s2")
    { var s = "abc"; var n = scond(s, true) } chk("s3")
    { var s = "abc"; var n = scond(s, false) } chk("s4")
    { var s = "abc"; var n = slen(spass(spass(s))) } chk("s5")
    { var s = "abc"; var w = s; var n = slen(w) } chk("s6")
    for var i: i32 = 0; i < 3; ++i { var s = f"abc{i}"; var n = scond(s, i == 1) chk("s7") }
    { var d: {string: R} = {"a": R(1), "b": R(2)}; dsink(d) } chk("d1")
    { var d: {string: R} = {"a": R(1), "b": R(2)}; d = dpass(d) } chk("d2")
    { var d: {string: R} = {"a": R(1), "b": R(2)}; var e = dpass(dpass(d)) } chk("d3")
    { var v: [string] = ["a", "b"]; ssv(v) } chk("sv1")
    { var h = VH(); h.add(R(1)); h.add(R(2)); vh(h) } chk("h1")
    { var h = VH(); h.add(R(1)); h = vhp(h) } chk("h2")
    { var h = VH(); h.add(R(1)); h = vhp(vhp(h)) } chk("h3")
    { var h = VH(); h.add(R(1)); vadd(h, R(3)) } chk("h4")
    { var h = VH(); var r = R(3); h.add(r); h.add(R(4)) } chk("h5")
    { var h = VH(); h.addv([R(1)]) ; var v: [R] = [R(2)]; h.addv(v) } chk("h6")
    { var v: [R] = []; var r = R(1); push_into(&v, r) } chk("p1")
    { var v: [R] = []; var r = R(1); push_if(&v, r, true) } chk("p2")
    { var v: [R] = []; var r = R(1); push_if(&v, r, false) } chk("p3")
    { var v: [R] = []; var r = R(1); push_loop(&v, r, 0) } chk("p4")
    { var v: [R] = []; var r = R(1); push_loop(&v, r, 3) } chk("p5")
    { var v: [R] = []; for var i: i32 = 0; i < 20; ++i { push_into(&v, R(i + 1)) } } chk("p6")
    { var v: [R] = []; for var i: i32 = 0; i < 20; ++i { var r = R(i + 1); push_if(&v, r, i % 3 == 0) } } chk("p7")
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
