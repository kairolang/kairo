// Covers file-scope statements and generators that take a destructive by-value
// parameter and consume it on some paths only. Every scenario balances.
import std::io::println
var made: i32 = 0
var released: i32 = 0
var fails: i32 = 0
class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id; made += 1 }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) {
        if self.id != 0 { released += 1; self.id = 0 }
    }
}
fn chk(const name: string) {
    if made != released { println(f"FAIL {name}: made {made} released {released}"); fails += 1 }
    made = 0
    released = 0
}
fn sink(r: R) { }
fn pass(r: R) -> R { return r }
fn cond(r: R, b: bool) { if b { sink(r) } }
fn gen_one(r: R) -> i32 { sink(r); return 1 }
fn gen_r(r: R, n: i32) -> yield i32 {
    for i in 0..n { yield i }
    sink(r)
}
fn gen_s(r: R, n: i32) -> yield i32 {
    for i in 0..n { yield i }
}
fn useg(r: R, n: i32) -> i32 { var t = 0; for x in gen_r(r, n) { t += x } return t }
fn upto(r: R, n: i32) -> i32 { sink(r); return n }

var ga = R(1)
sink(ga)
chk("top1")
var gc = R(3)
cond(gc, false)
chk("top3")
for var i: i32 = 0; i < 3; ++i {
    var t = R(5)
    cond(t, i == 1)
}
chk("top4")
{ var a = R(1); var t = useg(a, 3) }
chk("g1")
{ var a = R(1); var t = 0; for x in gen_s(a, 3) { t += x } }
chk("g2")
{ var a = R(1); var g = gen_r(a, 3); var q = 0; for x in g { q += x; break } }
chk("g3")
println(f"fails {fails}")

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --match-full-lines
// CHECK-NOT: FAIL
// CHECK: fails 0
