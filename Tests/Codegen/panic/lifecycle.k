// What an error with a lifecycle costs on its way (PANIC.md §4.3, §4.4):
// Big owns one malloc'd i32, moves only, and counts its moves; `live` counts
// the ones not yet destroyed. A `panic Big(n)` builds the payload in place
// (no move); each widening (`fwd`) moves it once; a `try` with two or more
// sites moves it into its slot once and out into the dispatch's local once
// (§4.4's move-out), and the slot is destroyed there, so every arm exit --
// a fall through, `return`, `break`, a re-panic -- destroys it exactly once.
// The counts below are the minimum the design allows, at -O0 and -O2. A
// leak or a double destroy shows as `live` != 0; an invalid read under
// valgrind (PANIC.md §4.5a B and F, re-verified for P6).
ffi "c" import "stdlib.h"
import std::io::println

var live: i32 = 0
var moves: i32 = 0
var copies: i32 = 0

class Big {
    var p: unsafe *i32
    pub fn Big(self, v: i32) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = v
        live += 1
    }
    @move
    fn Big(self, other: Self) {
        self.p = other.p
        unsafe { other.p = &null }
        live += 1
        moves += 1
    }
    fn op delete(self) {
        if self.p != &null { unsafe { free(self.p as unsafe *void) } }
        live -= 1
    }
    pub fn get(const self) -> i32 { return *self.p }
}
struct Small { var code: i32 }

fn fail_big(n: i32) panic(Big) -> i32 {
    if n < 0 { panic Big(n) }
    return n
}
fn fail_small(n: i32) panic(Small) -> i32 {
    if n == 7 { panic Small { code: 7 } }
    return n
}
fn both(n: i32) panic -> i32 { return fail_big(fail_small(n)) }
fn propagate(n: i32) panic -> i32 { var v = both(n); return v + 1 }

// B: two sites, exhaustive.
fn b(n: i32) -> i32 {
    var port: i32 = 0
    try { port = fail_big(fail_small(n)) } catch e: Big { port = e.get() } catch e: Small { port = 80 + e.code }
    return port
}
// F: nested.
fn f(n: i32) -> i32 {
    var r: i32 = 0
    try {
        try { r = both(n) } catch e: Small { r = 1 }
    } catch e: Big { r = e.get() }
    return r
}
fn rp(n: i32) panic -> i32 {
    try { return both(n) } catch e: Small { return 0 } catch e: Big { panic e }
}
fn rp2(n: i32) panic -> i32 {
    var x = 0
    try { x = fail_small(n) + fail_big(n) } catch e: Small { return 0 } catch e: Big { panic e }
    return x
}
fn early(n: i32) -> i32 {
    while true {
        try { var a = fail_big(n) + fail_small(n) } catch e: Big { break } catch e: Small { return 1 }
    }
    return 2
}

fn report(tag: i32) {
    println(f"{tag}: live={live} moves={moves}")
    moves = 0
}

fn main() -> i32 {
    if b(-3) != -3 { return 1 }
    report(1)
    if b(7) != 87 { return 2 }
    if f(-4) != -4 { return 3 }
    report(3)
    if f(7) != 1 { return 4 }
    if (try propagate(-5) catch e: Big => e.get() catch => 0) != -5 { return 5 }
    report(5)
    if (try rp(-6) catch e: Big => e.get() catch => 0) != -6 { return 6 }
    report(6)
    if (try rp2(-8) catch e: Big => e.get() catch => 0) != -8 { return 7 }
    report(7)
    if early(-1) != 2 { return 8 }
    report(8)
    if live != 0 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe | %FileCheck %s
// B: Big raised in place, widened into the slot (1), moved out (1).
// CHECK: 1: live=0 moves=2
// F: widened by the tail return of both() (1), sunk from the inner try to
// the outer slot (1), moved out (1).
// CHECK-NEXT: 3: live=0 moves=3
// CHECK-NEXT: 5: live=0 moves=2
// CHECK-NEXT: 6: live=0 moves=2
// CHECK-NEXT: 7: live=0 moves=3
// CHECK-NEXT: 8: live=0 moves=2
