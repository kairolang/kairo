// Static partial moves of a field out of a local (ownership.mdx, Moving a
// part) and their boundary: the same field moved through different
// statements, different fields on different paths, refill and whole
// reassignment, loops, early returns, panics between part moves, nested and
// three-field records in different field orders, a field with a destructor
// body, a generic instance, a base class, a closure, a pointer to the
// local. R counts live objects: made equals released after each scenario,
// in both modes, with the same destruction order of the live fields.
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

class P2 { var a: R; var b: R; fn P2(self, x: i32, y: i32) { self.a = R(x); self.b = R(y) } }
class P3 { var c: R; var a: R; var b: R; fn P3(self, x: i32) { self.c = R(x); self.a = R(x + 1); self.b = R(x + 2) } }
class Deep { var p: P2; var z: R; fn Deep(self, x: i32) { self.p = P2(x, x + 1); self.z = R(x + 2) } }
class DD { var a: R; var b: R; fn DD(self, x: i32) { self.a = R(x); self.b = R(x + 1) } fn op finally(self) { if self.a.id != 0 { println(f"~DD {self.a.id} {self.b.id}") } } }
class Outer { var d: DD; var r: R; fn Outer(self, x: i32) { self.d = DD(x); self.r = R(x + 2) } }
class <T, U> G { var a: T; var b: U; fn G(self, x: T, y: U) { self.a = x; self.b = y } }
class S { var s: i32 = 0 }
class Bs { var x: R; fn Bs(self, v: i32) { self.x = R(v) } }
class Dv derives Bs { var y: R; var z: R; fn Dv(self, v: i32) { Bs::Bs(self, v); self.y = R(v + 1); self.z = R(v + 2) } }
fn take_p2(p: P2) { println(f"p2 {p.a.id} {p.b.id}") }

fn s_basic() { var p = P2(1, 2); var x = p.a; println(f"x {x.id}") }
fn s_diff_stmts(c: bool) { var p = P2(3, 4); if c { var x = p.a } else { take(p.a) }; println("ds") }
fn s_diff_paths(c: bool) { var p = P2(5, 6); if c { var x = p.a } else { var y = p.b }; println("dp") }
fn s_same_both(c: bool) { var p = P2(7, 8); if c { var x = p.a; var y = p.b } else { take(p.b); take(p.a) }; println("sb") }
fn s_then_refill() { var p = P2(9, 10); var x = p.a; p.a = R(90); println(f"{p.a.id}") }
fn s_then_whole() { var p = P2(11, 12); var x = p.a; p = P2(110, 120); println(f"{p.a.id}") }
fn s_then_other(c: bool) { var p = P2(13, 14); var x = p.a; if c { var y = p.b }; println("so") }
fn s_loop(n: i32) { var p = P2(15, 16); for i in 0..n { var x = p.a; p.a = R(150 + i) }; println("sl") }
fn s_loop_once(n: i32) { var p = P2(17, 18); for i in 0..n { if i == 1 { var x = p.a; break } }; println("slo") }
fn s_early(c: bool) { var p = P2(19, 20); if c { return }; var x = p.a; println("se") }
fn s_early2(c: bool) { var p = P2(21, 22); var x = p.a; if c { return }; println("se2") }
fn s_panic(x: i32) panic { var p = P3(23); var m = p.a; may(x); var n = p.b; println("sp") }
fn s_panic2(x: i32) panic { var p = P3(26); may(x); var m = p.a; println("sp2") }
fn s_deep() { var d = Deep(29); var x = d.p.a; println("deep") }
fn s_deep2(c: bool) { var d = Deep(32); var x = d.p.a; if c { var y = d.z }; println("deep2") }
fn s_p3_orders() { var p = P3(35); var x = p.a; println("p3") }
fn s_p3_c() { var p = P3(38); var x = p.c; println("p3c") }
fn s_p3_b() { var p = P3(41); var x = p.b; println("p3b") }
fn s_p3_ca() { var p = P3(44); var x = p.c; var y = p.a; println("p3ca") }
fn s_p3_all() { var p = P3(47); var x = p.c; var y = p.a; var z = p.b; println("p3all") }
fn s_dd() { var o = Outer(50); var x = o.r; println("dd") }
fn s_dd2() { var o = Outer(53); var x = o.d; println("dd2") }
fn s_dd3() { var d = DD(56); var x = d.a; println("dd3") }
fn s_gen() { var g = G<R, R>(R(59), R(60)); var x = g.a; println("gen") }
fn s_gen2(c: bool) { var g = G<R, i32>(R(61), 5); if c { var x = g.a }; println("gen2") }
fn s_base() { var d = Dv(62); var x = d.y; println("base") }
fn s_base_x() { var d = Dv(65); var x = d.x; println("basex") }
fn s_closure() { var p = P2(68, 69); var f = fn () -> i32 { return 1 }; var x = p.a; println("scl") }
fn s_cap_part() { var p = P2(70, 71); var f = fn ()|p| -> i32 { return p.a.id }; println(f"f {f()}") }
fn s_param() { var p = P2(72, 73); take(p.a); println("sparam") }
fn s_ret() -> R { var p = P2(74, 75); return p.a }
fn s_ret_cond(c: bool) -> R { var p = P2(76, 77); if c { return p.b }; return p.a }
fn s_addr(c: bool) { var p = P2(78, 79); var *q = &p; var x = p.a; println(f"q {q->b.id}") }
fn s_addr2() { var p = P2(80, 81); var *q = &p.b; var x = p.a; println(f"q {q->id}") }
fn s_whole_after(c: bool) { var p = P2(82, 83); if c { var x = p.a; p.a = R(820) }; take_p2(p) }
fn s_both_then_whole() { var p = P2(84, 85); var x = p.a; var y = p.b; p = P2(840, 850); println("bw") }
fn s_nested_assign() { var d = Deep(86); var x = d.p.a; d.p.a = R(860); println("na") }
fn s_loop_cond(n: i32) { var p = P3(87); for i in 0..n { if i == 1 { var x = p.a; p.a = R(870) } } ; println("lc") }
fn s_try(x: i32) { var p = P2(90, 91); try { var m = p.a; may(x) } catch { println("c") }; println("st") }
fn s_match(k: i32) { var p = P3(92); match k { case 0 { var x = p.a } case 1 { var y = p.b } default { var x = p.a } } }
fn s_gen_part() -> yield i32 { var p = P2(95, 96); var x = p.a; yield 1; yield 2 }

fn main() -> i32 {
    made = 0
    s_basic(); chk("s_basic")
    for c in [true,false] { s_diff_stmts(c); chk("s_diff_stmts") }
    for c in [true,false] { s_diff_paths(c); chk("s_diff_paths") }
    for c in [true,false] { s_same_both(c); chk("s_same_both") }
    s_then_refill(); chk("s_then_refill")
    s_then_whole(); chk("s_then_whole")
    for c in [true,false] { s_then_other(c); chk("s_then_other") }
    for n in 0..3 { s_loop(n); chk("s_loop") }
    for n in 0..4 { s_loop_once(n); chk("s_loop_once") }
    for c in [true,false] { s_early(c); chk("s_early") }
    for c in [true,false] { s_early2(c); chk("s_early2") }
    for x in 0..2 { try { s_panic(x) } catch { println("c") }; chk("s_panic") }
    for x in 0..2 { try { s_panic2(x) } catch { println("c") }; chk("s_panic2") }
    s_deep(); chk("s_deep")
    for c in [true,false] { s_deep2(c); chk("s_deep2") }
    s_p3_orders(); chk("s_p3_orders"); s_p3_c(); chk("s_p3_c"); s_p3_b(); chk("s_p3_b"); s_p3_ca(); chk("s_p3_ca"); s_p3_all(); chk("s_p3_all")
    s_dd(); chk("s_dd"); s_dd2(); chk("s_dd2"); s_dd3(); chk("s_dd3")
    s_gen(); chk("s_gen")
    for c in [true,false] { s_gen2(c); chk("s_gen2") }
    s_base(); chk("s_base"); s_base_x(); chk("s_base_x")
    s_closure(); chk("s_closure"); s_cap_part(); chk("s_cap_part"); s_param(); chk("s_param")
    { var r = s_ret(); println(f"r {r.id}") }; chk("s_ret")
    for c in [true,false] { { var r = s_ret_cond(c); println(f"r {r.id}") }; chk("s_ret_cond") }
    for c in [true,false] { s_addr(c); chk("s_addr") }
    s_addr2(); chk("s_addr2")
    for c in [true,false] { s_whole_after(c); chk("s_whole_after") }
    s_both_then_whole(); chk("s_both_then_whole")
    s_nested_assign(); chk("s_nested_assign")
    for n in 0..3 { s_loop_cond(n); chk("s_loop_cond") }
    for x in 0..2 { s_try(x); chk("s_try") }
    for k in 0..3 { s_match(k); chk("s_match") }
    for v in s_gen_part() { println(f"g {v}"); break }; chk("s_gen_part1")
    for v in s_gen_part() { println(f"g {v}") }; chk("s_gen_part2")
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
