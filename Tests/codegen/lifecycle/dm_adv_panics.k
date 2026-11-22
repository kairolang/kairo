// Moves and panics (panic.mdx): a panicking call between a local's
// declaration and its move, a panic propagating with some locals moved, catch
// arms that reassign or move, try/catch values, the scope-exit finally block.
// R counts live objects: made equals released after each scenario, in both
// modes, with the same destruction order.
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

struct Err { var code: i32 }
fn boom(x: i32) panic -> i32 {
    if x > 0 { panic Err { code: x } }
    return x
}
fn p_between(x: i32) panic {
    var a = R(1); var b = R(2)
    var v = may(x)
    take(a)
    var w = may(x)
    take(b)
}
fn p_prop_some(x: i32) panic {
    var a = R(3); var b = R(4); var d = R(5)
    take(a)
    may(x)
    take(b)
    println(f"d {d.id}")
}
fn p_try_inner(x: i32) {
    var a = R(6)
    try {
        take(a)
        may(x)
    } catch {
        println("caught")
    }
    println("end")
}
fn p_try_cond_move(x: i32) {
    var a = R(7)
    try {
        may(x)
        take(a)
    } catch {
        println("caught")
    }
    println("end")
}
fn p_catch_reassign(x: i32) {
    var a = R(8)
    try {
        take(a)
        may(x)
    } catch {
        a = R(80)
    }
    println("end")
}
fn p_catch_reassign2(x: i32) {
    var a = R(9)
    try {
        may(x)
        take(a)
        a = R(91)
    } catch {
        println("c")
    }
    println(f"a {a.id}")
}
fn p_catch_moves(x: i32) {
    var a = R(10)
    try {
        may(x)
    } catch {
        take(a)
    }
    println("end")
}
fn p_typed(x: i32) {
    var a = R(11)
    try {
        take(a)
        boom(x)
    } catch e: Err {
        println(f"err {e.code}")
    }
}
fn p_typed2(x: i32) {
    var a = R(12); var b = R(13)
    try {
        var v = boom(x)
        take(a)
    } catch e: Err {
        take(b)
    }
    println("end")
}
fn p_nested(x: i32) {
    var a = R(14); var b = R(15)
    try {
        try {
            take(a)
            may(x)
        } catch {
            take(b)
            may(x)
        }
    } catch {
        println("outer")
    }
    println("end")
}
fn p_rethrow(x: i32) panic {
    var a = R(16)
    try {
        take(a)
        may(x)
    } catch e {
        panic e
    }
}
fn p_try_value(x: i32) {
    var a = R(17)
    var v = try may(x) catch => consume(a)
    println(f"v {v}")
}
fn p_try_value2(x: i32) {
    var a = R(18)
    var v = try (may(x) + consume(a)) catch => 99
    println(f"v {v}")
}
fn p_loop(x: i32) {
    var a = R(19)
    for i in 0..3 {
        try {
            take(a)
            a = R(190 + i)
            may(x * i)
        } catch {
            println("caught loop")
            break
        }
    }
    println(f"a {a.id}")
}
fn p_loop2(x: i32) {
    var a = R(20)
    for i in 0..3 {
        try {
            may(x * i)
            take(a)
            a = R(200 + i)
        } catch {
            println("caught loop")
            continue
        }
    }
    println(f"a {a.id}")
}
fn p_finally(x: i32) panic {
    var a = R(21); var b = R(22)
    take(a)
    {
        finally { println("fin") }
        may(x)
        take(b)
    }
    println("after")
}
fn p_finally_move(x: i32) panic {
    var a = R(23)
    {
        finally { println("fin") }
        if x > 1 { take(a) }
        may(x)
    }
    println("after")
}
fn p_finally_fn(x: i32) panic {
    var a = R(24)
    finally { println("fn fin") }
    take(a)
    may(x)
}
fn p_finally_fn2(x: i32) panic {
    var a = R(25)
    finally { println("fn fin") }
    may(x)
    take(a)
}
fn p_ret_in_try(x: i32) -> i32 {
    var a = R(26)
    try {
        may(x)
        take(a)
        return 1
    } catch {
        return 2
    }
}
fn p_ret_in_try2(x: i32) -> R {
    var a = R(27)
    try {
        may(x)
        return a
    } catch {
        return R(270)
    }
}

fn main() -> i32 {
    for x in 0..2 { try { p_between(x) } catch { println("c") }; chk("p_between") }
    for x in 0..2 { try { p_prop_some(x) } catch { println("c") }; chk("p_prop_some") }
    for x in 0..2 { p_try_inner(x); chk("p_try_inner") }
    for x in 0..2 { p_try_cond_move(x); chk("p_try_cond_move") }
    for x in 0..2 { p_catch_reassign(x); chk("p_catch_reassign") }
    for x in 0..2 { p_catch_reassign2(x); chk("p_catch_reassign2") }
    for x in 0..2 { p_catch_moves(x); chk("p_catch_moves") }
    for x in 0..2 { p_typed(x); chk("p_typed") }
    for x in 0..2 { p_typed2(x); chk("p_typed2") }
    for x in 0..2 { p_nested(x); chk("p_nested") }
    for x in 0..2 { try { p_rethrow(x) } catch { println("c") }; chk("p_rethrow") }
    for x in 0..2 { p_try_value(x); chk("p_try_value") }
    for x in 0..2 { p_try_value2(x); chk("p_try_value2") }
    for x in 0..2 { p_loop(x); chk("p_loop") }
    for x in 0..2 { p_loop2(x); chk("p_loop2") }
    for x in 0..3 { try { p_finally(x) } catch { println("c") }; chk("p_finally") }
    for x in 0..3 { try { p_finally_move(x) } catch { println("c") }; chk("p_finally_move") }
    for x in 0..2 { try { p_finally_fn(x) } catch { println("c") }; chk("p_finally_fn") }
    for x in 0..2 { try { p_finally_fn2(x) } catch { println("c") }; chk("p_finally_fn2") }
    for x in 0..2 { println(f"r {p_ret_in_try(x)}"); chk("p_ret_in_try") }
    for x in 0..2 { var g = p_ret_in_try2(x); println(f"r {g.id}"); g.finally(); chk("p_ret_in_try2") }
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
