// Whole assignment to a local of a MOVE class that is live, moved or maybe
// moved (ownership.mdx, Moved-From State): a = f(a), a = b between locals,
// chains of moves, a swap through a temporary, reassignment on some
// iterations of a loop or inside try. R counts live objects: made equals
// released after each scenario, in both modes, with the same destruction
// order.
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

fn as_live() { var a = R(1); a = R(10); println(f"a {a.id}") }
fn as_dead() { var a = R(2); take(a); a = R(20); println(f"a {a.id}") }
fn as_maybe(c: bool) { var a = R(3); if c { take(a) }; a = R(30); println(f"a {a.id}") }
fn as_twice() { var a = R(4); a = R(40); a = R(41); println(f"a {a.id}") }
fn as_dead_twice() { var a = R(5); take(a); a = R(50); take(a); a = R(51); println(f"a {a.id}") }
fn as_f(c: bool) { var a = R(6); if c { a = bump(a) }; println(f"a {a.id}") }
fn as_f_twice() { var a = R(7); a = bump(a); a = bump(a); println(f"a {a.id}") }
fn as_pass() { var a = R(8); a = pass(a); println(f"a {a.id}") }
fn as_self() { var a = R(9); a = a; println(f"a {a.id}") }
fn as_self_cond(c: bool) { var a = R(11); if c { take(a) } else { a = a }; a = R(110) }
fn as_ab(c: bool) {
    var a = R(12); var b = R(13)
    if c { a = b; b = R(130) }
    println(f"{a.id} {b.id}")
}
fn as_ab_dead(c: bool) {
    var a = R(14); var b = R(15)
    take(a)
    if c { a = b; b = R(150) } else { a = R(140) }
    println(f"{a.id} {b.id}")
}
fn as_ab_noref(c: bool) {
    var a = R(16); var b = R(17)
    if c { a = b }
    println(f"{a.id}")
}
fn chain(c: bool) {
    var a = R(18)
    var b = a
    if c { var d = b; println(f"d {d.id}") }
    println("chain end")
}
fn chain3() {
    var a = R(19)
    var b = a
    var c = b
    var d = c
    println(f"d {d.id}")
}
fn chain_rebuild() {
    var a = R(21)
    var b = a
    a = R(210)
    var c = a
    a = R(211)
    var d = b
    println(f"{a.id} {c.id} {d.id}")
}
fn swap_tmp(c: bool) {
    var a = R(22); var b = R(23)
    if c {
        var t = a
        a = b
        b = t
    }
    println(f"{a.id} {b.id}")
}
fn swap_tmp_loop(n: i32) {
    var a = R(24); var b = R(25)
    for i in 0..n {
        var t = a
        a = b
        b = t
    }
    println(f"{a.id} {b.id}")
}
fn swap_cond_in_loop() {
    var a = R(26); var b = R(27)
    for i in 0..4 {
        if i % 2 == 0 {
            var t = a
            a = b
            b = t
        } else {
            b = R(270 + i)
        }
    }
    println(f"{a.id} {b.id}")
}
fn re_in_loop(n: i32) {
    var a = R(28)
    for i in 0..4 {
        if i == n { take(a); a = R(280 + i) } else if i == n + 1 { a = R(290 + i) }
    }
    println(f"a {a.id}")
}
fn re_every() {
    var a = R(31)
    for i in 0..4 { a = R(310 + i) }
    println(f"a {a.id}")
}
fn re_after_loop_break(n: i32) {
    var a = R(32)
    for i in 0..4 {
        if i == n { take(a); break }
    }
    a = R(320)
    println(f"a {a.id}")
}
fn assign_from_call_of_self(c: bool) {
    var a = R(33)
    if c { take(a) }
    a = R(consume(R(331)))
    println(f"a {a.id}")
}
fn assign_cond_value(c: bool) {
    var a = R(34); var b = R(35)
    a = if (c) => b else => R(350)
    println(f"a {a.id}")
}
fn assign_coalesce(c: bool) {
    var a = R(36); var b = R(37)
    var o: R? = null
    if c { o = R(370) }
    a = o ?? b
    println(f"a {a.id}")
}
fn assign_declared_late(c: bool) {
    var a = R(38)
    var b = R(39)
    if c { a = b }
    take(a)
}
fn assign_in_try(x: i32) {
    var a = R(40)
    try { a = R(may(x) + 400) } catch { println("c") }
    println(f"a {a.id}")
}
fn assign_in_try_dead(x: i32) {
    var a = R(41)
    take(a)
    try { a = R(may(x) + 410) } catch { a = R(411) }
    println(f"a {a.id}")
}
fn assign_arg_panics(x: i32) {
    var a = R(42)
    take(a)
    try { a = bump(R(may(x) + 5)) } catch { println("c") ; a = R(421) }
    println(f"a {a.id}")
}

fn main() -> i32 {
    as_live(); chk("as_live")
    as_dead(); chk("as_dead")
    for c in [true, false] { as_maybe(c); chk("as_maybe") }
    as_twice(); chk("as_twice")
    as_dead_twice(); chk("as_dead_twice")
    for c in [true, false] { as_f(c); chk("as_f") }
    as_f_twice(); chk("as_f_twice")
    as_pass(); chk("as_pass")
    as_self(); chk("as_self")
    for c in [true, false] { as_self_cond(c); chk("as_self_cond") }
    for c in [true, false] { as_ab(c); chk("as_ab") }
    for c in [true, false] { as_ab_dead(c); chk("as_ab_dead") }
    for c in [true, false] { as_ab_noref(c); chk("as_ab_noref") }
    for c in [true, false] { chain(c); chk("chain") }
    chain3(); chk("chain3")
    chain_rebuild(); chk("chain_rebuild")
    for c in [true, false] { swap_tmp(c); chk("swap_tmp") }
    for n in 0..4 { swap_tmp_loop(n); chk("swap_tmp_loop") }
    swap_cond_in_loop(); chk("swap_cond_in_loop")
    for n in 0..5 { re_in_loop(n); chk("re_in_loop") }
    re_every(); chk("re_every")
    for n in 0..5 { re_after_loop_break(n); chk("re_after_loop_break") }
    for c in [true, false] { assign_from_call_of_self(c); chk("assign_from_call_of_self") }
    for c in [true, false] { assign_cond_value(c); chk("assign_cond_value") }
    for c in [true, false] { assign_coalesce(c); chk("assign_coalesce") }
    for c in [true, false] { assign_declared_late(c); chk("assign_declared_late") }
    for x in 0..2 { assign_in_try(x); chk("assign_in_try") }
    for x in 0..2 { assign_in_try_dead(x); chk("assign_in_try_dead") }
    for x in 0..2 { assign_arg_panics(x); chk("assign_arg_panics") }
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
