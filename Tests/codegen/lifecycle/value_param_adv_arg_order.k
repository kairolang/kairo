// Covers results built from a moved record parameter and assigned back to its own
// local, and calls whose other argument can leave or change the call. Every
// scenario balances and the values the callee reads are the caller's.
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
fn mkr(i: i32) -> R { return R(i) }
fn sink(r: R) { }
fn rd(r: R) -> i32 { return r.id }
class Pair { var a: R; var b: R
    fn Pair(self, x: R, y: R) { self.a = x; self.b = y }
    @move fn Pair(self, o: Self) { self.a = o.a; self.b = o.b }
}
fn setg() -> i32 { return 5 }
fn tup(p: R, q: i32) -> i32 { sink(p); return q }
fn tupm(p: R, q: i32) -> i32 { var x = p; return q + x.id }
fn mkp(i: i32) -> Pair { return Pair(R(i), R(i + 1)) }
fn flip(p: Pair) -> Pair { return Pair(p.b, p.a) }
fn flip2(p: Pair) -> Pair { var q = Pair(p.b, p.a); return q }
fn first(p: Pair) -> R { return p.a }
fn second_only(p: Pair) -> Pair { var t = p.a; return Pair(R(99), p.b) }
fn dv(a: i32, b: i32) -> i32 { return a / b }
fn divp(p: R, a: i32, b: i32) -> i32 { sink(p); return a }

fn main() -> i32 {
    made = 0
    { var p = mkp(1); p = flip(p) } chk("fl1")
    { var p = mkp(1); p = flip2(p) } chk("fl2")
    { var p = mkp(1); p = flip(flip(p)) } chk("fl3")
    { var p = mkp(1); var q = first(p) } chk("fl4")
    { var p = mkp(1); p = second_only(p) } chk("fl5")
    { var p = mkp(1); p = flip(p); if p.a.id != 2 { println(f"FAIL flipval {p.a.id}"); fails += 1 } } chk("fl6")
    { var p = mkp(1); var q = flip(p); if q.a.id != 2 || q.b.id != 1 { println(f"FAIL flipval2 {q.a.id} {q.b.id}"); fails += 1 } } chk("fl7")
    { var v: [i32] = [1, 2]; var a = R(1); try { tup(a, v[1]) } catch { } } chk("idx3")
    { var a = R(1); var v = tup(a, setg()) } chk("setg")
    println(f"fails {fails}")
    return fails
}

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
