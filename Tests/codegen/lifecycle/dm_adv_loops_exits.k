// Moves inside loops (break and continue before and after the move and the
// rebuild, labelled exits, zero iterations) and returns on every path
// (early returns between moves, survivors destroyed in reverse order, return
// of a moved and re-made local). R counts live objects: made equals released
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

fn brk_before(n: i32) {
    var a = R(1)
    for i in 0..3 {
        if i == n { break }
        take(a)
        a = R(10 + i)
    }
    println("end")
}
fn brk_after_move(n: i32) {
    var a = R(2)
    for i in 0..3 {
        if i == n { take(a); break }
        println(f"i {i}")
    }
}
fn brk_after_rebuild(n: i32) {
    var a = R(3)
    for i in 0..4 {
        take(a)
        a = R(30 + i)
        if i == n { break }
    }
    println(f"a {a.id}")
}
fn cont_before(n: i32) {
    var a = R(4)
    for i in 0..4 {
        if i == n { continue }
        take(a)
        a = R(40 + i)
    }
    println(f"a {a.id}")
}
fn cont_between(n: i32) {
    var a = R(5)
    for i in 0..4 {
        take(a)
        if i == n { a = R(50); continue }
        a = R(60 + i)
    }
    println(f"a {a.id}")
}
fn while_true_move(n: i32) {
    var a = R(6)
    var i = 0
    while true {
        i += 1
        if i > n {
            take(a)
            break
        }
    }
    println("wt end")
}
fn while_true_rebuild(n: i32) {
    var a = R(7)
    var i = 0
    while true {
        take(a)
        a = R(70 + i)
        i += 1
        if i > n { break }
    }
    println(f"a {a.id}")
}
fn loop_kw(n: i32) {
    var a = R(8)
    var i = 0
    loop {
        if i == n { break }
        i += 1
    }
    take(a)
}
fn nested_label(n: i32) {
    var a = R(9); var b = R(90)
    outer: for i in 0..3 {
        for j in 0..3 {
            if j == n { take(a); a = R(92); break outer }
            if i == n { take(b); b = R(91); continue outer }
        }
    }
    println("nl end")
}
fn nested_label2(n: i32) {
    var a = R(11)
    var k = 0
    outer: while k < 3 {
        k += 1
        for j in 0..3 {
            if j == 1 && k == n { take(a); a = R(110 + k); continue outer }
            if j == 2 && k == 3 { break outer }
        }
    }
    println(f"a {a.id}")
}
fn zero_iter(n: i32) {
    var a = R(12)
    for i in 0..n { take(a); a = R(120 + i) }
    println(f"a {a.id}")
}
fn zero_iter_move(n: i32) {
    var a = R(13)
    for i in 0..n { take(a); break }
    println("zi end")
}
fn outside_moved_inside(c: bool) {
    var a = R(14)
    for i in 0..3 {
        if c && i == 1 { take(a); a = R(140) }
    }
    println(f"a {a.id}")
}
fn outside_moved_inside_nomove(c: bool) {
    var a = R(15)
    var moved = false
    for i in 0..3 {
        if c && i == 1 { take(a); moved = true; break }
    }
    println(f"moved {moved}")
}
fn per_iter_local(n: i32) {
    for i in 0..3 {
        var a = R(16 + i)
        if i == n { take(a); continue }
        if i == n + 1 { break }
        println(f"keep {a.id}")
    }
}
fn two_locals_loop(n: i32) {
    var a = R(17); var b = R(18)
    for i in 0..3 {
        if i == n { take(a); a = R(170) } else { take(b); b = R(180 + i) }
    }
    println(f"{a.id} {b.id}")
}
fn while_cond_decl(n: i32) {
    var i = 0
    while i < n {
        var a = R(19 + i)
        i += 1
        if i == 2 { take(a); continue }
        println(f"w {a.id}")
    }
}
fn early_before(c: bool) {
    var a = R(20)
    if c { return }
    take(a)
}
fn early_between(x: i32) {
    var a = R(21); var b = R(22)
    take(a)
    if x == 0 { return }
    take(b)
}
fn early_between2(x: i32) {
    var a = R(23); var b = R(24); var d = R(25)
    if x == 0 { return }
    take(b)
    if x == 1 { return }
    take(a)
    if x == 2 { return }
    println("all")
}
fn early_nested(x: i32) {
    var a = R(26); var b = R(27)
    if x > 0 {
        var c = R(28)
        if x > 1 {
            take(a)
            if x > 2 { return }
            take(c)
        }
        take(b)
    }
    println("en end")
}
fn early_in_loop(x: i32) {
    var a = R(29); var b = R(30)
    for i in 0..3 {
        if i == x { return }
        take(a)
        a = R(290 + i)
    }
    take(b)
}
fn survivors(x: i32) {
    var a = R(31); var b = R(32); var c = R(33); var d = R(34)
    if x == 1 { take(b) }
    if x == 2 { take(a); take(d) }
    println("surv end")
}
fn give(c: bool) -> R {
    var a = R(35); var b = R(36)
    if c { return a }
    return b
}
fn give_moved(c: bool) -> R {
    var a = R(37)
    if c { take(a); a = R(370) }
    return a
}
fn give_twice(c: bool) -> R {
    var a = R(38)
    if c { var t = a; return t }
    return a
}
fn give_remade() -> R {
    var a = R(39)
    take(a)
    a = R(390)
    return a
}
fn give_in_loop() -> R {
    var a = R(40)
    for i in 0..3 {
        if i == 2 { return a }
        take(a)
        a = R(400 + i)
    }
    return R(0 + 9)
}
fn give_expr(c: bool) -> R {
    var a = R(41); var b = R(42)
    return if (c) => a else => b
}
fn give_pass(c: bool) -> R {
    var a = R(43)
    if c { return pass(a) }
    return pass(R(430))
}

fn main() -> i32 {
    for n in 0..4 { brk_before(n); chk("brk_before") }
    for n in 0..4 { brk_after_move(n); chk("brk_after_move") }
    for n in 0..4 { brk_after_rebuild(n); chk("brk_after_rebuild") }
    for n in 0..5 { cont_before(n); chk("cont_before") }
    for n in 0..5 { cont_between(n); chk("cont_between") }
    for n in 0..3 { while_true_move(n); chk("while_true_move") }
    for n in 0..3 { while_true_rebuild(n); chk("while_true_rebuild") }
    for n in 0..3 { loop_kw(n); chk("loop_kw") }
    for n in 0..4 { nested_label(n); chk("nested_label") }
    for n in 0..4 { nested_label2(n); chk("nested_label2") }
    for n in 0..3 { zero_iter(n); chk("zero_iter") }
    for n in 0..3 { zero_iter_move(n); chk("zero_iter_move") }
    for c in [true, false] { outside_moved_inside(c); chk("outside_moved_inside") }
    for c in [true, false] { outside_moved_inside_nomove(c); chk("outside_moved_inside_nomove") }
    for n in 0..4 { per_iter_local(n); chk("per_iter_local") }
    for n in 0..4 { two_locals_loop(n); chk("two_locals_loop") }
    for n in 0..4 { while_cond_decl(n); chk("while_cond_decl") }
    for c in [true, false] { early_before(c); chk("early_before") }
    for x in 0..2 { early_between(x); chk("early_between") }
    for x in 0..4 { early_between2(x); chk("early_between2") }
    for x in 0..4 { early_nested(x); chk("early_nested") }
    for x in 0..4 { early_in_loop(x); chk("early_in_loop") }
    for x in 0..3 { survivors(x); chk("survivors") }
    for c in [true, false] { var g = give(c); println(f"g {g.id}"); g.finally(); chk("give") }
    for c in [true, false] { var g = give_moved(c); println(f"g {g.id}"); g.finally(); chk("give_moved") }
    for c in [true, false] { var g = give_twice(c); println(f"g {g.id}"); g.finally(); chk("give_twice") }
    { var g = give_remade(); println(f"g {g.id}"); g.finally(); chk("give_remade") }
    { var g = give_in_loop(); println(f"g {g.id}"); g.finally(); chk("give_in_loop") }
    for c in [true, false] { var g = give_expr(c); println(f"g {g.id}"); g.finally(); chk("give_expr") }
    for c in [true, false] { var g = give_pass(c); println(f"g {g.id}"); g.finally(); chk("give_pass") }
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
