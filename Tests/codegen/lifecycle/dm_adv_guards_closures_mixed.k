// Moves in match guards and arms, scope-exit finally blocks, closures
// capturing by pointer or by move, recursion, an operator taking the value,
// try expressions, a loop condition that moves, and locals moved both into a
// @move parameter (which leaves the moved-from object to be destroyed) and
// by a real transfer. R counts live objects: made equals released after
// each scenario, in both modes, with the same destruction order.
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

class Acc {
    var n: i32 = 0
    fn op +(self, r: R) -> i32 { return self.n + r.id }
}
fn take_mv(@move r: R) { println(f"took mv {r.id}") }
fn guard(k: i32, c: bool) {
    var a = R(1)
    match k {
        case 0 where yes(a) { println("g0") }
        case 1 { println("g1") }
        default { println("gd") }
    }
    println("guard end")
}
fn guard_rebuild(k: i32) {
    var a = R(2)
    match k {
        case 0 where yes(a) { println("g0") ; a = R(20) }
        case 1 { take(a); a = R(21) }
        default { a = R(0 + 22) ; take(a); a = R(0 + 23) }
    }
    println(f"a {a.id}")
}
fn match_stmt_moves(k: i32) {
    var a = R(3); var b = R(4)
    match k {
        case 0 { take(a) }
        case 1 { take(b) }
        case 2 { take(a); take(b) }
        default { println("none") }
    }
    println("ms end")
}
fn match_return(k: i32) -> i32 {
    var a = R(5)
    match k {
        case 0 { take(a); return 1 }
        case 1 { return 2 }
        default { }
    }
    return 3
}
fn fin_move(x: i32) {
    var a = R(6)
    {
        finally { take(a) }
        println("body")
    }
    println("after")
}
fn fin_move_cond(x: i32) {
    var a = R(7)
    {
        finally { if x > 0 { take(a) } }
        println("body")
    }
    println("after")
}
fn fin_fn_move(x: i32) {
    var a = R(8)
    finally { println("fin") }
    if x > 0 { take(a) }
    println("body")
}
fn cap_ptr(c: bool) {
    var a = R(9)
    var f = fn ()|*a| { println(f"cap {a->id}") }
    f()
    if c { take(a) }
}
fn cap_move_nested(c: bool) {
    var a = R(10)
    var f = fn () {
        var b = R(100)
        var g = fn ()|b| { take(b) }
        g()
    }
    f()
    if c { take(a) }
}
fn rec(n: i32, c: bool) {
    var a = R(n + 100)
    if n > 0 { rec(n - 1, c) }
    if c || n % 2 == 0 { take(a) }
}
fn rec_ret(n: i32) -> R {
    var a = R(n + 200)
    if n == 0 { return a }
    var b = rec_ret(n - 1)
    if n % 2 == 0 { take(a); return b }
    return a
}
fn op_arg(c: bool) {
    var acc = Acc()
    var a = R(11)
    var s = 0
    if c { s = acc + a }
    println(f"s {s}")
}
fn mixed1(c: bool) {
    var a = R(12)
    if c { take_mv(a) } else { take(a) }
    println("m1")
}
fn mixed2(c: bool) {
    var a = R(13)
    take(a)
    a = R(130)
    if c { take_mv(a) }
    println("m2")
}
fn mixed3(c: bool) {
    var a = R(14)
    take_mv(a)
    a = R(140)
    if c { take(a) }
    println("m3")
}
fn mixed4(n: i32) {
    var a = R(15)
    for i in 0..3 {
        if i == n { take_mv(a); a = R(150 + i) }
        else if i == n + 1 { take(a); a = R(160 + i) }
    }
}
fn try_expr(x: i32) {
    var a = R(16)
    var v = try (may(x) + consume(a)) catch => -1
    println(f"v {v}")
}
fn try_expr_move_catch(x: i32) {
    var a = R(17)
    var v = try may(x) catch => consume(a)
    println(f"v {v}")
}
fn labelled_match(k: i32) {
    var a = R(18); var b = R(19)
    outer: for i in 0..3 {
        match (i + k) % 3 {
            case 0 { take(a); a = R(180 + i) }
            case 1 { take(b); break outer }
            default { continue outer }
        }
    }
    println("lm end")
}
fn while_cond_move(n: i32) {
    var a = R(20)
    var i = 0
    while consume(a) >= 0 && i < n {
        i += 1
        a = R(200 + i)
    }
}
fn while_cond_move2(n: i32) {
    var a = R(21)
    var i = 0
    while i < n && yes(a) {
        i += 1
        a = R(210 + i)
    }
    println(f"i {i}")
}
fn opt_cond(c: bool) {
    var a = R(22)
    var o: R? = null
    if c { o = R(220) }
    if o? && yes(a) { println("both") }
    println("oc end")
}
fn opt_cond2(c: bool) {
    var a = R(23)
    var o: i32? = null
    if c { o = 1 }
    if o? { take(a) } else { println("no") }
}
fn unreach(x: i32) -> i32 {
    var a = R(24)
    if x >= 0 { take(a); return 1 }
    println("never")
    return 0
}
fn many_returns(x: i32) -> R {
    var a = R(25); var b = R(26); var c = R(27)
    if x == 0 { return a }
    if x == 1 { take(a); return b }
    if x == 2 { take(a); take(b); return c }
    return R(250)
}

fn main() -> i32 {
    made = 0
    for k in 0..3 { for c in [true,false] { guard(k, c); chk("guard") } }
    for k in 0..3 { guard_rebuild(k); chk("guard_rebuild") }
    for k in 0..4 { match_stmt_moves(k); chk("match_stmt_moves") }
    for k in 0..3 { println(f"r {match_return(k)}"); chk("match_return") }
    for x in 0..2 { fin_move(x); chk("fin_move") }
    for x in 0..2 { fin_move_cond(x); chk("fin_move_cond") }
    for x in 0..2 { fin_fn_move(x); chk("fin_fn_move") }
    for c in [true,false] { cap_ptr(c); chk("cap_ptr") }
    for c in [true,false] { cap_move_nested(c); chk("cap_move_nested") }
    for c in [true,false] { rec(3, c); chk("rec") }
    for n in 0..4 { { var r = rec_ret(n); println(f"r {r.id}") }; chk("rec_ret") }
    for c in [true,false] { op_arg(c); chk("op_arg") }
    for c in [true,false] { mixed1(c); chk("mixed1") }
    for c in [true,false] { mixed2(c); chk("mixed2") }
    for c in [true,false] { mixed3(c); chk("mixed3") }
    for n in 0..4 { mixed4(n); chk("mixed4") }
    for x in 0..2 { try_expr(x); chk("try_expr") }
    for x in 0..2 { try_expr_move_catch(x); chk("try_expr_move_catch") }
    for k in 0..3 { labelled_match(k); chk("labelled_match") }
    for n in 0..4 { while_cond_move(n); chk("while_cond_move") }
    for n in 0..4 { while_cond_move2(n); chk("while_cond_move2") }
    for c in [true,false] { opt_cond(c); chk("opt_cond") }
    for c in [true,false] { opt_cond2(c); chk("opt_cond2") }
    for x in 0..2 { println(f"r {unreach(x)}"); chk("unreach") }
    for x in 0..4 { { var r = many_returns(x); println(f"r {r.id}") }; chk("many_returns") }
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
