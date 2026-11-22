// Closure capture by move is a destructive move of the captured local
// (ownership.mdx, Moved-From State): a closure built on one path, in a loop,
// returned, passed on, nested, next to a pointer capture, in try, in a
// generator, in a match arm, in a conditionally evaluated position, with the
// local assigned again afterwards. R counts live objects: made equals
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

fn run(f: fn() -> i32) -> i32 { return f() }
fn run_twice(f: fn() -> i32) -> i32 { return f() + f() }
fn mk(c: bool) -> fn() -> i32 {
    var a = R(1)
    if c { return fn () -> i32 { return a.id } }
    return fn () -> i32 { return 0 }
}
fn mk2() -> fn() -> i32 { var a = R(2); var b = R(3); return fn () -> i32 { return a.id + b.id } }
fn mk_arg(f: fn() -> i32, r: R) -> i32 { return f() + r.id }

fn cl_cond(c: bool) { var a = R(4); var f = fn () -> i32 { return 0 }; if c { f = fn () -> i32 { return a.id } }; println(f"f {f()}") }
fn cl_cond_rebuild(c: bool) { var a = R(5); if c { var f = fn () -> i32 { return a.id }; println(f"f {f()}"); a = R(50) } println(f"a {a.id}") }
fn cl_loop(n: i32) { for i in 0..n { var a = R(6 + i * 10); var f = fn () -> i32 { return a.id }; println(f"f {f()}") } }
fn cl_loop_outer(n: i32) {
    var a = R(7)
    for i in 0..n { var f = fn () -> i32 { return a.id }; println(f"f {f()}"); a = R(70 + i) }
    println(f"a {a.id}")
}
fn cl_two(c: bool) { var a = R(8); var b = R(9); var f = fn () -> i32 { return a.id }; if c { var g = fn () -> i32 { return b.id }; println(f"g {g()}") } println(f"f {f()}") }
fn cl_never_called(c: bool) { var a = R(10); var f = fn () -> i32 { return a.id }; if c { println(f"f {f()}") } }
fn cl_many() { var a = R(11); var f = fn () -> i32 { return a.id }; println(f"{f()} {f()} {f()}") }
fn cl_move_inside(c: bool) { var a = R(12); var f = fn () -> i32 { take(a); return 1 }; if c { println(f"f {f()}") } }
fn cl_ret(c: bool) { var f = mk(c); println(f"f {f()}") }
fn cl_ret2() { var f = mk2(); println(f"f {f()}") }
fn cl_arg(c: bool) { var a = R(13); if c { println(f"r {run(fn () -> i32 { return a.id })}") } }
fn cl_arg_twice() { var a = R(14); println(f"r {run_twice(fn () -> i32 { return a.id })}") }
fn cl_arg_other(c: bool) { var a = R(15); var b = R(16); println(f"r {mk_arg(fn () -> i32 { return a.id }, b)}") }
fn cl_nested(c: bool) { var a = R(23); var f = fn () -> i32 { var g = fn () -> i32 { return a.id }; return g() }; if c { println(f"f {f()}") } }
fn cl_ptr_cap(c: bool) { var a = R(24); var b = R(25); var f = fn ()|*a, *b| -> i32 { return a->id + b->id }; if c { println(f"f {f()}") } }
fn cl_copy_cap(c: bool) { var a = R(26); var n = 5; var f = fn ()|a, n| -> i32 { return a.id + n }; n = 7; if c { println(f"f {f()}") } }
fn cl_try(x: i32) { var a = R(27); try { var f = fn () -> i32 { return a.id }; may(x); println(f"f {f()}") } catch { println("c") } }
fn cl_try2(x: i32) { var a = R(28); try { may(x); var f = fn () -> i32 { return a.id }; println(f"f {f()}") } catch { println("c") } }
fn cl_match(k: i32) { var a = R(29); var b = R(30); match k { case 0 { var f = fn () -> i32 { return a.id }; println(f"f {f()}") } case 1 { var f = fn () -> i32 { return b.id }; println(f"f {f()}") } default { } } }
fn cl_and(c: bool) { var a = R(31); var ok = c && run(fn () -> i32 { return a.id }) > 0; println(f"ok {ok}") }
fn cl_or(c: bool) { var a = R(32); var ok = c || run(fn () -> i32 { return a.id }) > 0; println(f"ok {ok}") }
fn opt_f(c: bool) -> (fn() -> i32)? { if c { return fn () -> i32 { return 1 } }; return null }
fn cl_coalesce(c: bool) { var a = R(33); var o? = opt_f(c); var f = o ?? fn () -> i32 { return a.id }; println(f"f {f()}") }
fn cl_ifx(c: bool) { var a = R(34); var b = R(35); var f = if (c) => fn () -> i32 { return a.id } else => fn () -> i32 { return b.id }; println(f"f {f()}") }
fn cl_reassign(c: bool) { var a = R(36); var f = fn () -> i32 { return a.id }; a = R(360); println(f"{f()} {a.id}") }
fn cl_reassign_cond(c: bool) { var a = R(37); if c { var f = fn () -> i32 { return a.id }; println(f"{f()}"); a = R(370) }; println(f"{a.id}") }
fn cl_early(c: bool) { var a = R(38); var f = fn () -> i32 { return a.id }; if c { return }; println(f"f {f()}") }
fn cl_early2(c: bool) { var a = R(39); if c { return }; var f = fn () -> i32 { return a.id }; println(f"f {f()}") }
fn cl_break(n: i32) { var a = R(40); for i in 0..3 { if i == n { var f = fn () -> i32 { return a.id }; println(f"{f()}"); break } } ; println("end") }
fn gen_cl(n: i32) -> yield i32 { var a = R(41); var f = fn () -> i32 { return a.id }; for i in 0..n { yield f() + i } }
fn use_gen(n: i32, stop: i32) { for v in gen_cl(n) { println(f"v {v}"); if v == stop { break } } }
fn gen_cl2(n: i32) -> yield i32 { var a = R(42); yield 1; if n > 0 { var f = fn () -> i32 { return a.id }; yield f() } yield 3 }
fn use_gen2(n: i32, stop: i32) { for v in gen_cl2(n) { if v == stop { break } } }
fn cl_inout_param(r: R, c: bool) { var f = fn () -> i32 { return r.id }; if c { println(f"f {f()}") } }
fn cl_pass_param(c: bool) { cl_inout_param(R(43), c) }
fn cl_fin(c: bool) { var a = R(44); var f = fn () -> i32 { return a.id }; { finally { println("fin") }; if c { println(f"f {f()}") } } }

fn main() -> i32 {
    made = 0
    for c in [true,false] { cl_cond(c); chk("cl_cond") }
    for c in [true,false] { cl_cond_rebuild(c); chk("cl_cond_rebuild") }
    for n in 0..3 { cl_loop(n); chk("cl_loop") }
    for n in 0..3 { cl_loop_outer(n); chk("cl_loop_outer") }
    for c in [true,false] { cl_two(c); chk("cl_two") }
    for c in [true,false] { cl_never_called(c); chk("cl_never_called") }
    cl_many(); chk("cl_many")
    for c in [true,false] { cl_move_inside(c); chk("cl_move_inside") }
    for c in [true,false] { cl_ret(c); chk("cl_ret") }
    cl_ret2(); chk("cl_ret2")
    for c in [true,false] { cl_arg(c); chk("cl_arg") }
    cl_arg_twice(); chk("cl_arg_twice")
    for c in [true,false] { cl_arg_other(c); chk("cl_arg_other") }
    for c in [true,false] { cl_nested(c); chk("cl_nested") }
    for c in [true,false] { cl_ptr_cap(c); chk("cl_ptr_cap") }
    for c in [true,false] { cl_copy_cap(c); chk("cl_copy_cap") }
    for x in 0..2 { cl_try(x); chk("cl_try") }
    for x in 0..2 { cl_try2(x); chk("cl_try2") }
    for k in 0..3 { cl_match(k); chk("cl_match") }
    for c in [true,false] { cl_and(c); chk("cl_and") }
    for c in [true,false] { cl_or(c); chk("cl_or") }
    for c in [true,false] { cl_coalesce(c); chk("cl_coalesce") }
    for c in [true,false] { cl_ifx(c); chk("cl_ifx") }
    for c in [true,false] { cl_reassign(c); chk("cl_reassign") }
    for c in [true,false] { cl_reassign_cond(c); chk("cl_reassign_cond") }
    for c in [true,false] { cl_early(c); chk("cl_early") }
    for c in [true,false] { cl_early2(c); chk("cl_early2") }
    for n in 0..4 { cl_break(n); chk("cl_break") }
    for n in 0..3 { for s in 0..4 { use_gen(n, s); chk("use_gen") } }
    for n in 0..2 { for s in 0..4 { use_gen2(n, s); chk("use_gen2") } }
    for c in [true,false] { cl_pass_param(c); chk("cl_pass_param") }
    for c in [true,false] { cl_fin(c); chk("cl_fin") }
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
