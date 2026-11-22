// Moves in else-if chains, range expressions, generator binders and match
// binders, try with break and continue, a rethrowing catch, deeply nested
// loops with labelled exits, a try expression with a returning arm, and
// guard chains. R counts live objects: made equals released after each
// scenario, in both modes, with the same destruction order.
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

enum Slot { Full { r: R }, Empty }
fn mk(n: i32) -> yield R {
    for i in 0..n { yield R(1000 + i) }
}
fn mk_slot(c: bool) -> Slot { if c { return Slot::Full { r: R(2000) } }; return Slot::Empty }

fn chain(k: i32) {
    var a = R(1); var b = R(2); var d = R(3)
    if consume(a) > 5 { println("a big") }
    else if k > 0 && consume(b) > 0 { println("b") }
    else if k > 1 && yes(d) { println("d") }
    println("chain end")
}
fn chain_rebuild(k: i32) {
    var a = R(4); var b = R(5)
    if consume(a) > 5 { a = R(40) } else if k > 0 && consume(b) > 0 { b = R(50); a = R(41) } else { a = R(42); b = R(51) }
    println(f"{a.id} {b.id}")
}
fn range_move(n: i32) {
    var a = R(6)
    for i in 0..(consume(a) - 6 + n) { println(f"i {i}") }
    println("rm end")
}
fn binder_move(c: bool, n: i32) {
    for r in mk(n) {
        if c { take(r) } else { println(f"keep {r.id}") }
    }
}
fn binder_move_some(n: i32) {
    for r in mk(n) {
        if r.id % 2 == 0 { take(r) }
    }
}
fn binder_break(n: i32, k: i32) {
    var i = 0
    for r in mk(n) {
        if i == k { take(r); break }
        i += 1
    }
}
fn match_binder(c: bool, d: bool) {
    var s = mk_slot(c)
    match s {
        case .Full(var r) { if d { take(r) } }
        default { println("empty") }
    }
}
fn nested_try_loop(n: i32) {
    var a = R(7)
    for i in 0..3 {
        try {
            take(a)
            a = R(70 + i)
            if i == n { may(1) }
        } catch {
            println("caught")
            continue
        }
    }
    println(f"a {a.id}")
}
fn try_break(n: i32) {
    var a = R(8); var b = R(9)
    for i in 0..3 {
        try {
            if i == n { take(a); a = R(81); may(1) }
            may(0)
        } catch {
            a = R(80)
            break
        }
    }
    println("tb end")
}
fn catch_rethrow(x: i32) panic {
    var a = R(10); var b = R(11)
    try {
        take(a)
        may(x)
    } catch e {
        take(b)
        panic e
    }
    println("cr end")
}
fn nested3(n: i32) {
    var a = R(12)
    for i in 0..2 {
        for j in 0..2 {
            for k in 0..2 {
                if i * 4 + j * 2 + k == n { take(a); a = R(120 + n) }
            }
        }
        if i == 1 && n == 99 { println("x") }
    }
    println(f"a {a.id}")
}
fn nested3_break(n: i32) {
    var a = R(13)
    outer: for i in 0..2 {
        for j in 0..2 {
            for k in 0..2 {
                if i * 4 + j * 2 + k == n { take(a); break outer }
            }
        }
    }
    println("n3b end")
}
fn if_expr_return(x: i32) -> i32 {
    var a = R(14)
    var v = try (may(x) + consume(a)) catch => return 5
    return v
}
fn guard_chain(k: i32) {
    var a = R(15); var b = R(16)
    match k {
        case 0 where yes(a) { println("0a") }
        case 0 where yes(b) { println("0b") }
        case 1 { take(a) }
        default { }
    }
}
fn stmt_expr_loop(n: i32) {
    var a = R(17)
    for i in 0..n {
        var t = ({ take(a); a = R(170 + i); i })
        println(f"t {t}")
    }
}

fn main() -> i32 {
    made = 0
    for k in 0..3 { chain(k); chk("chain") }
    for k in 0..3 { chain_rebuild(k); chk("chain_rebuild") }
    for n in 0..3 { range_move(n); chk("range_move") }
    for c in [true,false] { for n in 0..3 { binder_move(c, n); chk("binder_move") } }
    for n in 0..4 { binder_move_some(n); chk("binder_move_some") }
    for n in 0..3 { for k in 0..4 { binder_break(n, k); chk("binder_break") } }
    for c in [true,false] { for d in [true,false] { match_binder(c, d); chk("match_binder") } }
    for n in 0..4 { nested_try_loop(n); chk("nested_try_loop") }
    for n in 0..4 { try_break(n); chk("try_break") }
    for x in 0..2 { try { catch_rethrow(x) } catch { println("c") }; chk("catch_rethrow") }
    for n in 0..8 { nested3(n); chk("nested3") }
    for n in 0..9 { nested3_break(n); chk("nested3_break") }
    for c in 0..2 { println(f"r {if_expr_return(c)}"); chk("if_expr_return") }
    for k in 0..3 { guard_chain(k); chk("guard_chain") }
    for n in 0..3 { stmt_expr_loop(n); chk("stmt_expr_loop") }
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
