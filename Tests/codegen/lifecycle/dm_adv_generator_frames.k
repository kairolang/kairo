// A generator stored in a variable and dropped before, while or after it
// runs (its frame is destroyed while suspended), with locals moved before
// and after a yield and a MOVE class as the yielded type. R counts live
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
fn gen_r(n: i32) -> yield R {
    var a = R(5)
    for i in 0..n {
        var t = R(50 + i)
        yield t
    }
    yield a
}
fn gen_r2(n: i32) -> yield R {
    var a = R(6); var b = R(7)
    if n > 0 { yield a } 
    yield R(70)
    if n > 1 { yield b }
}
fn stored_a(n: i32, stop: i32) {
    var it = gen_a(n)
    for v in it { if v == stop { break } }
}
fn stored_never(n: i32) { var it = gen_a(n); println("never") }
fn stored_b(stop: i32) {
    var it = gen_b(2)
    for v in it { if v == stop { break } }
}
fn stored_c(n: i32, stop: i32) {
    var it = gen_c(n)
    for v in it { if v == stop { break } }
}
fn stored_r(n: i32, k: i32) {
    var it = gen_r(n)
    var i = 0
    for r in it { println(f"r {r.id}"); i += 1; if i == k { break } }
}
fn stored_r2(n: i32, k: i32) {
    var it = gen_r2(n)
    var i = 0
    for r in it { println(f"r {r.id}"); i += 1; if i == k { break } }
}
fn direct_r(n: i32, k: i32) {
    var i = 0
    for r in gen_r2(n) { println(f"r {r.id}"); i += 1; if i == k { break } }
}
fn direct_r_take(n: i32, k: i32) {
    var i = 0
    for r in gen_r2(n) { take(r); i += 1; if i == k { break } }
}

fn main() -> i32 {
    made = 0
    for n in 0..3 { for s in 0..3 { stored_a(n, s); chk("stored_a") } }
    for n in 0..2 { stored_never(n); chk("stored_never") }
    for s in 0..4 { stored_b(s); chk("stored_b") }
    for n in 0..3 { for s in 0..3 { stored_c(n, s); chk("stored_c") } }
    for n in 0..3 { for k in 0..5 { stored_r(n, k); chk("stored_r") } }
    for n in 0..3 { for k in 0..5 { stored_r2(n, k); chk("stored_r2") } }
    for n in 0..3 { for k in 0..5 { direct_r(n, k); chk("direct_r") } }
    for n in 0..3 { for k in 0..5 { direct_r_take(n, k); chk("direct_r_take") } }
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
