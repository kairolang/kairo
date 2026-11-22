// Conditionally evaluated sub-expressions that contain a move (ownership.mdx,
// Moved-From State): the right operand of && and ||, if and match expression
// arms, ??, ?., call arguments next to a panicking or conditional argument,
// named and default arguments. Every scenario creates and destroys the same
// number of live R objects (a moved-from R is empty and counts nothing), in
// both modes, and the two modes print the same destruction order.
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

fn and_r(c: bool) { var a = R(1); if pick(c) && yes(a) { println("t") }; println("e") }
fn or_r(c: bool) { var a = R(2); if pick(c) || yes(a) { println("t") }; println("e") }
fn and_val(c: bool) { var a = R(3); var b = pick(c) && no(a); println(f"b {b}") }
fn or_val(c: bool) { var a = R(4); var b = pick(c) || yes(a); println(f"b {b}") }
fn and_chain(x: i32) {
    var a = R(5); var b = R(6)
    var v = pick(x > 0) && yes(a) && pick(x > 1) && yes(b)
    println(f"v {v}")
}
fn or_chain(x: i32) {
    var a = R(7); var b = R(8)
    var v = pick(x > 0) || yes(a) || pick(x > 1) || yes(b)
    println(f"v {v}")
}
fn ifx(c: bool) {
    var a = R(9); var b = R(10)
    var r = if (c) => (a) else => b
    println(f"chose {r.id}")
}
fn ifx_one(c: bool) {
    var a = R(11)
    var r = if (c) => (a) else => R(110)
    println(f"chose {r.id}")
}
fn ifx_call(c: bool) {
    var a = R(12)
    var n = if (c) => consume(a) else => 0
    println(f"n {n}")
}
fn ifx_nested(x: i32) {
    var a = R(13); var b = R(14); var d = R(15)
    var r = if (x == 0) => (a) else => (if (x == 1) => (b) else => d)
    println(f"chose {r.id}")
}
fn mx(k: i32) {
    var a = R(16); var b = R(17)
    var r = match k {
        case 0 => pass(a)
        default => R(160)
    }
    println(f"r {r.id}")
}
fn mx_call(k: i32) {
    var a = R(18); var b = R(19)
    var n = match k {
        case 0 => consume(a)
        case 1 => consume(b)
        default => 0
    }
    println(f"n {n}")
}
fn coalesce(c: bool) {
    var a = R(20)
    var v = opt_int(c) ?? consume(a)
    println(f"v {v}")
}
fn coalesce_chain(x: i32) {
    var a = R(21); var b = R(22)
    var v = (if (x == 0) => opt_int(false) else => opt_int(true)) ?? consume(a) 
    println(f"v {v}")
    var w = opt_int(x > 5) ?? opt_int(x > 3) ?? consume(b)
    println(f"w {w}")
}
fn coalesce_r(c: bool) {
    var a = R(23)
    var o: R? = null
    if c { o = R(230) }
    var r = o ?? a
    println(f"r {r.id}")
}
class Obj {
    var v: i32 = 0
    fn Obj(self, v: i32) { self.v = v }
    fn eat(self, r: R) -> i32 { println(f"eat {r.id}"); return self.v }
}
fn safe_call(c: bool) {
    var a = R(24)
    var o: Obj? = null
    if c { o = Obj(1) }
    var v? = o?.eat(a)
    println(f"v {v ?? -1}")
}
fn while_cond(n: i32) {
    var a = R(25)
    var i = 0
    while i < n && yes(a) {
        i += 1
        break
    }
    println("wc end")
}
fn if_cond_move(c: bool) {
    var a = R(26)
    if c {
        if consume(a) > 0 { println("pos") }
    }
    println("ic end")
}
fn cond_move_ifx(c: bool) {
    var a = R(27)
    if consume(a) > 100 || c { println("x") }
    println("end")
}
fn arg_cond(c: bool) {
    var a = R(28)
    two(a, if (c) => 1 else => 2)
}
fn arg_later_cond(c: bool) {
    var a = R(29); var b = R(290)
    two(if (c) => a else => b, 1)
}
fn arg_later_panic(x: i32) {
    var a = R(30)
    try { two(a, may(x)) } catch { println("caught") }
}
fn arg_two_moves(x: i32) {
    var a = R(31); var b = R(32)
    try {
        two(a, may(x))
        take(b)
    } catch { println("caught") }
}
fn named_oo(x: i32) {
    var a = R(33)
    try { two_r(r: a, x: may(x)) } catch { println("caught") }
}
fn two_by(r: R, s: R) { println(f"two_by {r.id} {s.id}") }
fn two_args_moves(c: bool) {
    var a = R(34); var b = R(35)
    if c { two_by(s: b, r: a) } else { take(a) }
}
fn dflt(r: R, n: i32 = 7) { println(f"dflt {r.id} {n}") }
fn dflt_user(c: bool) {
    var a = R(36)
    if c { dflt(a) } else { dflt(a, 8) }
}
fn dflt_skip(r: R, n: i32 = 7, s: R = R(370)) { println(f"dflt_skip {r.id} {n} {s.id}") }
fn dflt_skip_user(c: bool) {
    var a = R(37)
    if c { dflt_skip(a) }
}
fn dflt_named(c: bool) {
    var a = R(38)
    var b = R(39)
    if c { dflt_skip(r: a, s: b) }
}

fn main() -> i32 {
    for c in [true, false] { and_r(c); chk("and_r") }
    for c in [true, false] { or_r(c); chk("or_r") }
    for c in [true, false] { and_val(c); chk("and_val") }
    for c in [true, false] { or_val(c); chk("or_val") }
    for x in 0..3 { and_chain(x); chk("and_chain") }
    for x in 0..3 { or_chain(x); chk("or_chain") }
    for c in [true, false] { ifx(c); chk("ifx") }
    for c in [true, false] { ifx_one(c); chk("ifx_one") }
    for c in [true, false] { ifx_call(c); chk("ifx_call") }
    for x in 0..3 { ifx_nested(x); chk("ifx_nested") }
    for k in 0..3 { mx(k); chk("mx") }
    for k in 0..3 { mx_call(k); chk("mx_call") }
    for c in [true, false] { coalesce(c); chk("coalesce") }
    for x in 0..2 { coalesce_chain(x); chk("coalesce_chain") }
    for c in [true, false] { coalesce_r(c); chk("coalesce_r") }
    for c in [true, false] { safe_call(c); chk("safe_call") }
    for n in 0..2 { while_cond(n); chk("while_cond") }
    for c in [true, false] { if_cond_move(c); chk("if_cond_move") }
    for c in [true, false] { cond_move_ifx(c); chk("cond_move_ifx") }
    for c in [true, false] { arg_cond(c); chk("arg_cond") }
    for c in [true, false] { arg_later_cond(c); chk("arg_later_cond") }
    for x in 0..2 { arg_later_panic(x); chk("arg_later_panic") }
    for x in 0..2 { arg_two_moves(x); chk("arg_two_moves") }
    for x in 0..2 { named_oo(x); chk("named_oo") }
    for c in [true, false] { two_args_moves(c); chk("two_args_moves") }
    for c in [true, false] { dflt_user(c); chk("dflt_user") }
    for c in [true, false] { dflt_skip_user(c); chk("dflt_skip_user") }
    for c in [true, false] { dflt_named(c); chk("dflt_named") }
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
