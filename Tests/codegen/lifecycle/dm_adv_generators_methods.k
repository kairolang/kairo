// Moves in generators, methods, operators, delayed initialisation, the
// @inout and @move parameter modes, a pointer to a moved local, many locals
// moved by a bit mask, and a MOVE class used as the panic type. R counts live
// objects: made equals released after each scenario, in both modes, with the
// same destruction order.
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

class D {
    var id: i32 = 0
    fn D(self) { made += 1; self.id = 7 }
    fn D(self, id: i32) { self.id = id; made += 1 }
    @move fn D(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { if self.id != 0 { println(f"~D {self.id}"); released += 1; self.id = 0 } }
}
fn take_d(d: D) { println(f"took d {d.id}") }
fn take_mv(@move r: R) { println(f"took mv {r.id}") }
fn inout_r(@inout r: R) { r.id += 1 }

fn gen_a(n: i32) -> yield i32 {
    var a = R(1)
    for i in 0..n { yield i }
    take(a)
    yield 100
}
fn gen_b(n: i32) -> yield i32 {
    var a = R(2); var b = R(3)
    take(a)
    yield 1
    if n > 1 { take(b) }
    yield 2
    yield 3
}
fn gen_c(n: i32) -> yield i32 {
    var a = R(4)
    for i in 0..n {
        yield i
        take(a)
        a = R(40 + i)
    }
    yield 99
}
fn gen_d() -> yield i32 {
    var a = R(5)
    var b = a
    yield 1
    yield 2
}
fn use_gen_a(n: i32, stop: i32) {
    for v in gen_a(n) { println(f"v {v}"); if v == stop { break } }
}
fn use_gen_b(stop: i32) {
    for v in gen_b(2) { println(f"v {v}"); if v == stop { break } }
}
fn use_gen_c(n: i32, stop: i32) {
    for v in gen_c(n) { println(f"v {v}"); if v == stop { break } }
}
fn use_gen_d(stop: i32) {
    for v in gen_d() { println(f"v {v}"); if v == stop { break } }
}
fn gen_nested(n: i32) -> yield i32 {
    for i in 0..n {
        var a = R(6 + i)
        yield i
        if i % 2 == 0 { take(a) }
    }
}
fn use_gen_nested(n: i32, stop: i32) {
    for v in gen_nested(n) { if v == stop { break } }
}

class M {
    var n: i32 = 0
    fn m1(self, c: bool) { var a = R(10 + self.n); if c { take(a) } }
    fn m2(self, c: bool) -> R { var a = R(20 + self.n); if c { return a }; return R(0 + 25) }
    fn op +(self, o: i32) -> R { var a = R(30); if o > 0 { take(a); return R(31) }; return a }
}
fn meth(c: bool) { var m = M(); m.m1(c) }
fn meth_ret(c: bool) { var m = M(); var r = m.m2(c); println(f"r {r.id}") }
fn op_ret(o: i32) { var m = M(); var r = m + o; println(f"r {r.id}") }

fn delayed(c: bool) {
    var d: D
    if c { d = D(1) }
    println(f"d {d.id}")
}
fn delayed_move(c: bool) {
    var d = D()
    if c { take_d(d); d = D(2) }
    println(f"d {d.id}")
}
fn mixed_mv(c: bool) {
    var a = R(7)
    if c { take_mv(a) }
    println("mm end")
}
fn mixed_mv_rebuild(c: bool) {
    var a = R(8)
    take_mv(a)
    a = R(80)
    if c { take(a) }
}
fn inout_then_move(c: bool) {
    var a = R(9)
    inout_r(&a)
    if c { take(a) }
}
fn finally_paths(x: i32) {
    var a = R(11)
    if x == 0 { a.finally() }
    else if x == 1 { take(a) }
    println("fp end")
}
fn finally_remake(x: i32) {
    var a = R(12)
    a.finally()
    a = R(120)
    if x > 0 { take(a) }
    println("fr end")
}
fn ptr_alias(c: bool) {
    var a = R(13)
    var *p = &a
    if c { take(a); a = R(130) }
    println(f"p {p->id}")
}
fn many(n: i32) {
    var a = R(14); var b = R(15); var c = R(16); var d = R(17); var e = R(18)
    if (n & 1) != 0 { take(a) }
    if (n & 2) != 0 { take(b) }
    if (n & 4) != 0 { take(c) }
    if (n & 8) != 0 { take(d) }
    if (n & 16) != 0 { take(e) }
}
fn many_ass(n: i32) {
    var a = R(19); var b = R(20); var c = R(21)
    for i in 0..3 {
        if ((n >> i) & 1) != 0 { take(a); a = R(190 + i) }
        if ((n >> i) & 2) != 0 { take(b); b = R(200 + i) }
        if ((n >> i) & 4) != 0 { var t = c; c = R(210 + i) }
    }
}
fn a_in_cond_loop(n: i32) {
    var a = R(22)
    var i = 0
    while i < n {
        if i == 1 { i += 1; continue }
        take(a)
        a = R(220 + i)
        i += 1
    }
}
fn move_then_return_in_nested(x: i32) -> i32 {
    var a = R(23)
    for i in 0..3 {
        for j in 0..3 {
            if i == x && j == 1 { take(a); return 5 }
        }
    }
    return 0
}
fn early_after_decl() {
    return
    var a = R(0 + 24)
}
fn panic_obj(x: i32) panic {
    var a = R(25)
    if x > 0 { panic R(250) }
    take(a)
}
fn panic_obj_catch(x: i32) {
    var a = R(26)
    try { panic_obj(x); take(a) } catch e: R { println(f"caught {e.id}") }
    println("po end")
}

fn main() -> i32 {
    made = 0
    for n in 0..3 { for s in 0..3 { use_gen_a(n, s); chk("gen_a") } }
    for s in 0..4 { use_gen_b(s); chk("gen_b") }
    for n in 0..3 { for s in 0..3 { use_gen_c(n, s); chk("gen_c") } }
    for s in 0..3 { use_gen_d(s); chk("gen_d") }
    for n in 0..4 { for s in 0..4 { use_gen_nested(n, s); chk("gen_nested") } }
    for c in [true, false] { meth(c); chk("meth") }
    for c in [true, false] { meth_ret(c); chk("meth_ret") }
    for o in 0..2 { op_ret(o); chk("op_ret") }
    for c in [true, false] { delayed(c); chk("delayed") }
    for c in [true, false] { delayed_move(c); chk("delayed_move") }
    for c in [true, false] { mixed_mv(c); chk("mixed_mv") }
    for c in [true, false] { mixed_mv_rebuild(c); chk("mixed_mv_rebuild") }
    for c in [true, false] { inout_then_move(c); chk("inout_then_move") }
    for x in 0..3 { finally_paths(x); chk("finally_paths") }
    for x in 0..2 { finally_remake(x); chk("finally_remake") }
    for c in [true, false] { ptr_alias(c); chk("ptr_alias") }
    for n in 0..32 { many(n); chk("many") }
    for n in 0..64 { many_ass(n); chk("many_ass") }
    for n in 0..5 { a_in_cond_loop(n); chk("a_in_cond_loop") }
    for x in 0..4 { println(f"r {move_then_return_in_nested(x)}"); chk("nested_ret") }
    early_after_decl(); chk("early_after_decl")
    for x in 0..2 { panic_obj_catch(x); chk("panic_obj_catch") }
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
