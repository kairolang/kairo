// Covers a destructive by-value parameter while the callee stores through pointers to
// the caller's local before or after it consumes the parameter, or while a global
// pointer names the local. Every scenario balances and reads the right value.
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
var gdum: R = R(0)
var gp: *R = &gdum
fn mod(p: R, q: *R) -> i32 { *q = R(50); return p.id }
fn modm(p: R, q: *R) -> i32 { *q = R(50); sink(p); return 1 }
fn modm2(p: R, q: *R) -> R { var x = p; *q = R(60); return x }
fn viaglob(p: R) -> i32 { *gp = R(70); return p.id }
fn viaclo(p: R, f: fn() -> i32) -> i32 { f(); return p.id }
fn viaclom(p: R, f: fn() -> i32) -> i32 { f(); var x = p; return x.id }
fn viaclom2(p: R, f: fn() -> i32) -> i32 { var x = p; f(); return x.id }
fn mod2(p: R, q: *R, b: bool) -> i32 { if b { *q = R(50) } sink(p); return 1 }
fn two_ptr(p: R, q: *R) -> i32 { var r = q->id; sink(p); return r }
fn aliasrd(p: R, q: *R) -> i32 { var a = p.id; *q = R(51); return a + p.id }

fn main() -> i32 {
    made = 0
    { var a = R(1); var *pa = &a; var v = mod(a, pa); if v != 1 { println(f"FAIL mod {v}"); fails += 1 } } chk("mod")
    { var a = R(1); var *pa = &a; var v = modm(a, pa); } chk("modm")
    { var a = R(1); var *pa = &a; var r = modm2(a, pa); if r.id != 1 { println(f"FAIL modm2 {r.id}"); fails += 1 } } chk("modm2")
    { var a = R(1); gp = &a; var v = viaglob(a); if v != 1 { println(f"FAIL viaglob {v}"); fails += 1 } } chk("viaglob")
    { var a = R(1); var *pa = &a; mod2(a, pa, true) } chk("mod2")
    { var a = R(1); var *pa = &a; mod2(a, pa, false) } chk("mod2b")
    { var a = R(1); var *pa = &a; two_ptr(a, pa) } chk("two_ptr")
    { var a = R(1); var *pa = &a; var v = aliasrd(a, pa); if v != 2 { println(f"FAIL aliasrd {v}"); fails += 1 } } chk("aliasrd")
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
