// Structs, tuples, enums, vectors and a derived class holding a MOVE class,
// moved on some paths and rebuilt in loops. Only a MOVE class is
// destructive; the others behave as with -fno-destructive-moves. R counts
// live objects: made equals released after each scenario, in both modes,
// with the same destruction order.
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
            println(f"~R {self.id}")
            released += 1
            self.id = 0
        }
    }
}

fn chk(name: string) {
    if made != released {
        println(f"FAIL {name}: made {made} released {released}")
        fails += 1
    }
    made = 0
    released = 0
}

fn take(r: R) { println(f"took {r.id}") }
fn yes(r: R) -> bool { println(f"yes {r.id}"); return true }
fn no(r: R) -> bool { println(f"no {r.id}"); return false }
fn pick(c: bool) -> bool { return c }
fn consume(r: R) -> i32 { return r.id }
fn opt_int(c: bool) -> i32? {
    if c { return 1 }
    return null
}
fn may(x: i32) panic -> i32 {
    if x > 0 { panic "boom" }
    return x
}
fn two(r: R, x: i32) { println(f"two {r.id} {x}") }
fn two_r(x: i32, r: R) { println(f"two_r {r.id} {x}") }
fn bump(r: R) -> R { return R(r.id + 100) }
fn pass(r: R) -> R { return r }

struct S { var r: R; var n: i32 }
enum Slot { Full { r: R }, Empty }
class Base1 {
    var r: R
    fn Base1(self, x: i32) { self.r = R(x) }
}
class Der derives Base1 {
    var extra: R
    fn Der(self, x: i32) { Base1::Base1(self, x); self.extra = R(x + 1) }
}
fn take_s(s: S) { println(f"s {s.r.id}") }
fn take_t(t: (R, R)) { println(f"t {t.0.id}") }
fn take_slot(s: Slot) { match s { case .Full(const r) { println(f"full {r.id}") } default { println("empty") } } }
fn take_der(d: Der) { println(f"der {d.r.id} {d.extra.id}") }
fn take_arr(xs: [R]) { println(f"arr {xs.size()}") }

fn struct_local(c: bool) { var s = S { r: R(1), n: 2 }; if c { take_s(s) } }
fn struct_local2(c: bool) { var s = S { r: R(3), n: 2 }; if c { var t = s; println(f"{t.n}") } ; println("sl") }
fn struct_rebuild(n: i32) { var s = S { r: R(4), n: 2 }; for i in 0..n { take_s(s); s = S { r: R(40 + i), n: i } } }
fn tuple_local(c: bool) { var t = (R(5), R(6)); if c { take_t(t) } }
fn tuple_rebuild(n: i32) { var t = (R(7), R(8)); for i in 0..n { take_t(t); t = (R(70 + i), R(80 + i)) } }
fn enum_local(c: bool) { var s = Slot::Full { r: R(9) }; if c { take_slot(s) } }
fn enum_rebuild(n: i32) { var s = Slot::Full { r: R(10) }; for i in 0..n { take_slot(s); s = Slot::Full { r: R(100 + i) } } }
fn vec_local(c: bool) { var xs: [R] = []; xs.push(R(11)); xs.push(R(12)); if c { take_arr(xs) } }
fn vec_rebuild(n: i32) { var xs: [R] = []; xs.push(R(13)); for i in 0..n { take_arr(xs); xs = []; xs.push(R(130 + i)) } }
fn take_opt(o: R?) { println(f"opt {o?.id ?? -1}") }
fn der_local(c: bool) { var d = Der(16); if c { take_der(d) } }
fn der_rebuild(n: i32) { var d = Der(17); for i in 0..n { take_der(d); d = Der(170 + i * 10) } }
fn der_copy(c: bool) { var d = Der(18); var e = d; if c { var f = e; println(f"f {f.r.id}") } }
fn vec_of_struct(c: bool) { var xs: [S] = []; xs.push(S { r: R(19), n: 1 }); if c { var ys = xs; println(f"{ys.size()}") } }
fn tuple_ret(c: bool) -> (R, R) { var t = (R(20), R(21)); if c { return t }; return (R(22), R(23)) }
fn enum_ret(c: bool) -> Slot { var s = Slot::Full { r: R(24) }; if c { return s }; return Slot::Empty }
fn struct_ret(c: bool) -> S { var s = S { r: R(25), n: 1 }; if c { return s }; return S { r: R(26), n: 2 } }

fn main() -> i32 {
    made = 0
    for c in [true,false] { struct_local(c); chk("struct_local") }
    for c in [true,false] { struct_local2(c); chk("struct_local2") }
    for n in 0..3 { struct_rebuild(n); chk("struct_rebuild") }
    for c in [true,false] { tuple_local(c); chk("tuple_local") }
    for n in 0..3 { tuple_rebuild(n); chk("tuple_rebuild") }
    for c in [true,false] { enum_local(c); chk("enum_local") }
    for n in 0..3 { enum_rebuild(n); chk("enum_rebuild") }
    for c in [true,false] { vec_local(c); chk("vec_local") }
    for n in 0..3 { vec_rebuild(n); chk("vec_rebuild") }
    for c in [true,false] { der_local(c); chk("der_local") }
    for n in 0..3 { der_rebuild(n); chk("der_rebuild") }
    for c in [true,false] { der_copy(c); chk("der_copy") }
    for c in [true,false] { vec_of_struct(c); chk("vec_of_struct") }
    for c in [true,false] { { var t = tuple_ret(c); println(f"t {t.0.id}") }; chk("tuple_ret") }
    for c in [true,false] { { var t = enum_ret(c); take_slot(t) }; chk("enum_ret") }
    for c in [true,false] { { var t = struct_ret(c); println(f"s {t.r.id}") }; chk("struct_ret") }
    println(f"fails {fails}")
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe %t.out %t.off.out
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.exe > %t.out
// RUN: %t.off.exe > %t.off.out
// RUN: diff %t.out %t.off.out
// RUN: %FileCheck %s --check-prefix=OUT --input-file=%t.out
// OUT-NOT: FAIL
// OUT: fails 0
