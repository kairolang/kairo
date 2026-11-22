// Moving a field out of a local of a MOVE class (ownership.mdx, Moving a
// part): static and conditional partial moves, nested fields, a class with a
// destructor, loops that move and refill a field, panics around the move, a
// generator holding the record. R counts live objects: made equals released
// after each scenario, in both modes, with the same destruction order.
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

class Pair {
    var a: R
    var b: R
    fn Pair(self, x: i32, y: i32) { self.a = R(x); self.b = R(y) }
}
class Deep {
    var p: Pair
    var c: R
    fn Deep(self, x: i32) { self.p = Pair(x, x + 1); self.c = R(x + 2) }
}
class UD {
    var a: R
    var b: R
    fn UD(self, x: i32) { self.a = R(x); self.b = R(x + 1) }
    fn op finally(self) { println(f"~UD {self.a.id} {self.b.id}") }
}
class Three { var a: R; var b: R; var c: R
    fn Three(self, x: i32) { self.a = R(x); self.b = R(x + 1); self.c = R(x + 2) } }
fn take_pair(p: Pair) { println(f"pair {p.a.id} {p.b.id}") }

fn p_static() { var p = Pair(1, 2); var x = p.a; println(f"x {x.id}") }
fn p_static_take() { var p = Pair(3, 4); take(p.b); println("after") }
fn p_two() { var p = Pair(5, 6); var x = p.a; var y = p.b; println("two") }
fn p_deep() { var d = Deep(7); var x = d.p.a; println(f"x {x.id}") }
fn p_deep2() { var d = Deep(10); var x = d.p.a; var y = d.c; println("deep2") }
fn p_cond(c: bool) { var p = Pair(13, 14); if c { var x = p.a; println("moved a") }; println("cond end") }
fn p_cond2(c: bool) { var p = Pair(15, 16); if c { take(p.a) } else { take(p.b) } ; println("cond2 end") }
fn p_cond_whole(c: bool) { var p = Pair(17, 18); if c { take_pair(p) } else { var x = p.a; println("x") } }
fn p_early(c: bool) { var p = Pair(19, 20); if c { return }; var x = p.a; println("early end") }
fn p_loop(n: i32) { var p = Pair(21, 22); for i in 0..n { var x = p.a; p.a = R(210 + i) } println("loop end") }
fn p_reassign() { var p = Pair(23, 24); var x = p.a; p.a = R(230); println(f"p {p.a.id}") }
fn p_then_whole() { var p = Pair(25, 26); var x = p.a; p = Pair(250, 260); println("tw") }
fn p_ud() { var u = UD(27); var x = u.a; println("ud") }
fn p_three(n: i32) { var t = Three(30); if (n & 1) != 0 { var x = t.a; }; if (n & 2) != 0 { var y = t.b; } ; println("three") }
fn p_three_static() { var t = Three(40); var x = t.b; println("three static") }
fn p_panic(x: i32) panic { var p = Pair(37, 38); var m = p.a; may(x); println("p panic") }
fn p_panic2(x: i32) panic { var p = Pair(39, 40); may(x); var m = p.a; println("p panic2") }
fn p_ret(c: bool) -> R { var p = Pair(41, 42); if c { return p.a }; return p.b }
fn p_ret2() -> R { var p = Pair(43, 44); return p.a }
fn p_gen() -> yield i32 { var p = Pair(45, 46); var x = p.a; yield 1; yield 2 }
fn p_field_assign() { var p = Pair(47, 48); var q = Pair(49, 50); p.a = q.a; println("fa") }
fn p_swap_fields() { var p = Pair(51, 52); var t = p.a; p.a = p.b; p.b = t; println(f"{p.a.id} {p.b.id}") }
fn p_try(x: i32) { var p = Pair(53, 54); try { var m = p.a; may(x) } catch { println("c") } }
fn p_try2(x: i32) { var p = Pair(55, 56); try { may(x); var m = p.a } catch { println("c") } }

fn main() -> i32 {
    made = 0
    p_static(); chk("p_static")
    p_static_take(); chk("p_static_take")
    p_two(); chk("p_two")
    p_deep(); chk("p_deep")
    p_deep2(); chk("p_deep2")
    for c in [true,false] { p_cond(c); chk("p_cond") }
    for c in [true,false] { p_cond2(c); chk("p_cond2") }
    for c in [true,false] { p_cond_whole(c); chk("p_cond_whole") }
    for c in [true,false] { p_early(c); chk("p_early") }
    for n in 0..3 { p_loop(n); chk("p_loop") }
    p_reassign(); chk("p_reassign")
    p_then_whole(); chk("p_then_whole")
    p_ud(); chk("p_ud")
    for n in 0..4 { p_three(n); chk("p_three") }
    p_three_static(); chk("p_three_static")
    for x in 0..2 { try { p_panic(x) } catch { println("c") }; chk("p_panic") }
    for x in 0..2 { try { p_panic2(x) } catch { println("c") }; chk("p_panic2") }
    for c in [true,false] { { var r = p_ret(c); println(f"r {r.id}") }; chk("p_ret") }
    { var r = p_ret2(); println(f"r {r.id}") }; chk("p_ret2")
    for v in p_gen() { println(f"g {v}"); break }; chk("p_gen")
    for v in p_gen() { println(f"g {v}") }; chk("p_gen2")
    p_field_assign(); chk("p_field_assign")
    p_swap_fields(); chk("p_swap_fields")
    for x in 0..2 { p_try(x); chk("p_try") }
    for x in 0..2 { p_try2(x); chk("p_try2") }
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
