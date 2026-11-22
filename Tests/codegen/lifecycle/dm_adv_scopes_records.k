// Moves in shadowing scopes, closure bodies, records holding a MOVE class,
// generic class instances, containers, tuples and nullables. Containers,
// tuples and nullables are not destructive: they behave as with
// -fno-destructive-moves. R counts live objects: made equals released after
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

class Pair {
    var a: R
    var b: R
    fn Pair(self, x: i32, y: i32) { self.a = R(x); self.b = R(y) }
}
class Wrap {
    var r: R
    var n: i32 = 0
    fn Wrap(self, x: i32) { self.r = R(x) }
}
class <T> Box {
    var v: T
    fn Box(self, v: T) { self.v = v }
}
fn take_pair(p: Pair) { println(f"took pair {p.a.id} {p.b.id}") }
fn take_box(b: Box<R>) { println(f"took box {b.v.id}") }
fn <T> id_gen(x: T) -> T { return x }

fn sh_outer_live(c: bool) {
    var a = R(1)
    if c {
        var a = R(10)
        take(a)
    }
    println(f"a {a.id}")
}
fn sh_outer_moved(c: bool) {
    var a = R(2)
    {
        var a = R(20)
        if c { take(a) }
    }
    take(a)
}
fn sh_both(c: bool) {
    var a = R(3)
    {
        var a = R(30)
        if c { take(a) } else { println(f"inner {a.id}") }
    }
    if !c { take(a) }
}
fn sh_block_end() {
    var a = R(4)
    {
        var b = R(40)
        var c = b
        println("block end")
    }
    take(a)
}
fn sh_loop_shadow(n: i32) {
    var a = R(5)
    for i in 0..n {
        var a = R(50 + i)
        if i == 1 { take(a) }
    }
    println(f"a {a.id}")
}
fn cl_own_local(c: bool) {
    var f = fn (x: i32) {
        var a = R(6)
        if x > 0 { take(a) }
        println("body")
    }
    f(0)
    f(1)
}
fn cl_nested() {
    var f = fn (x: i32) {
        var a = R(7)
        var g = fn () { var b = R(70); take(b) }
        g()
        if x > 0 { take(a) }
    }
    f(0)
    f(1)
}
fn cl_capture(c: bool) {
    var a = R(8)
    var f = fn ()|a| { take(a) }
    if c { f() }
    println("cl end")
}
fn cl_ret_local() {
    var f = fn (x: i32) -> R {
        var a = R(9)
        if x > 0 { return a }
        return R(90)
    }
    var r = f(0)
    var s = f(1)
    println(f"{r.id} {s.id}")
}
fn rec_whole(c: bool) {
    var p = Pair(11, 12)
    if c { take_pair(p) }
    println("rec end")
}
fn rec_whole_var(c: bool) {
    var p = Pair(13, 14)
    if c { var q = p; println(f"q {q.a.id}") }
    println("rec end")
}
fn rec_rebuild(n: i32) {
    var p = Pair(15, 16)
    for i in 0..n { take_pair(p); p = Pair(150 + i, 160 + i) }
    println(f"p {p.a.id} {p.b.id}")
}
fn rec_wrap(c: bool) {
    var w = Wrap(17)
    var v = w
    if c { w = Wrap(170) }
    println(f"{v.r.id}")
}
fn rec_field(c: bool) {
    var p = Pair(18, 19)
    if c { var x = p.a; println(f"x {x.id}") }
    println("rec end")
}
fn rec_field_whole(c: bool) {
    var p = Pair(20, 21)
    var x = p.a
    if c { p.a = R(210); take_pair(p) }
}
fn gen_local(c: bool) {
    var b = Box<R>(R(22))
    if c { take_box(b) }
    println("gen end")
}
fn gen_local_assign(c: bool) {
    var b = Box<R>(R(23))
    take_box(b)
    if c { b = Box<R>(R(230)) }
    println("gen end")
}
fn gen_field(c: bool) {
    var b = Box<R>(R(24))
    var x = b.v
    if c { b.v = R(240) }
}
fn gen_fn(c: bool) {
    var a = R(25)
    var b = id_gen(a)
    if c { var d = id_gen(b); println(f"d {d.id}") }
}
fn gen_fn_move(c: bool) {
    var a = R(26)
    if c { var d = id_gen(a); println(f"d {d.id}") }
}
fn arr_local(c: bool) {
    var xs = [R(27), R(28)]
    if c { println(f"arr {xs.size()}") }
    println("arr end")
}
fn vec_local(c: bool) {
    var xs: [R] = []
    xs.push(R(29))
    xs.push(R(290))
    if c { var ys = xs; println(f"vec {ys.size()}") }
    println("vec end")
}
fn tup_local(c: bool) {
    var t = (R(30), 5)
    if c { var u = t; println(f"tup {u.1}") }
    println("tup end")
}
fn null_local(c: bool) {
    var o: R? = R(31)
    if c { println(f"null {o?.id ?? 0}") }
    println("null end")
}
fn null_local2(c: bool) {
    var o: R? = null
    if c { o = R(32) }
    println("null2 end")
}

fn main() -> i32 {
    for c in [true, false] { sh_outer_live(c); chk("sh_outer_live") }
    for c in [true, false] { sh_outer_moved(c); chk("sh_outer_moved") }
    for c in [true, false] { sh_both(c); chk("sh_both") }
    sh_block_end(); chk("sh_block_end")
    for n in 0..4 { sh_loop_shadow(n); chk("sh_loop_shadow") }
    cl_own_local(true); chk("cl_own_local")
    cl_nested(); chk("cl_nested")
    for c in [true, false] { cl_capture(c); chk("cl_capture") }
    cl_ret_local(); chk("cl_ret_local")
    for c in [true, false] { rec_whole(c); chk("rec_whole") }
    for c in [true, false] { rec_whole_var(c); chk("rec_whole_var") }
    for n in 0..3 { rec_rebuild(n); chk("rec_rebuild") }
    for c in [true, false] { rec_wrap(c); chk("rec_wrap") }
    for c in [true, false] { rec_field(c); chk("rec_field") }
    for c in [true, false] { rec_field_whole(c); chk("rec_field_whole") }
    for c in [true, false] { gen_local(c); chk("gen_local") }
    for c in [true, false] { gen_local_assign(c); chk("gen_local_assign") }
    for c in [true, false] { gen_field(c); chk("gen_field") }
    for c in [true, false] { gen_fn(c); chk("gen_fn") }
    for c in [true, false] { gen_fn_move(c); chk("gen_fn_move") }
    for c in [true, false] { arr_local(c); chk("arr_local") }
    for c in [true, false] { vec_local(c); chk("vec_local") }
    for c in [true, false] { tup_local(c); chk("tup_local") }
    for c in [true, false] { null_local(c); chk("null_local") }
    for c in [true, false] { null_local2(c); chk("null_local2") }
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
