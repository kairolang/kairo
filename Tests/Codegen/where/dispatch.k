// dispatch.k -- stdout
// `where` dispatch end to end (where.mdx): every group compiles to one
// function testing the guards in declaration order and calling the
// matching overload, with the unguarded one as the fallback.
import std::io::println
ffi "c" import "math.h"

// Basic Syntax.
fn root(x: f64) -> f64
  where x >= 0.0 {
    return sqrt(x)
}

fn root(x: f64) -> f64 {
    return 0.0   // fallback for negative input
}

fn safe_divide(a: i32, b: i32) -> i32
  where b != 0 && a >= 0 {
    return a / b
}

fn safe_divide(a: i32, b: i32) -> i32 {
    return 0   // fallback
}

// Declaration Order Determines Priority.
fn categorize(x: i32) -> string where x > 100  { return "high" }
fn categorize(x: i32) -> string where x > 0    { return "positive" }
fn categorize(x: i32) -> string                 { return "non-positive" }

// The fallback may be declared first; it is still tested last.
fn first_fallback(x: i32) -> i32 { return 0 }
fn first_fallback(x: i32) -> i32 where x == 7 { return 7 }

// Expression bodies.
fn pos(x: i32) -> i32 where x > 0 = x
fn pos(x: i32) -> i32 = 0

// Guards that cover every value need no fallback; the last is not tested.
fn sign(x: i32) -> i32 where x >= 0 { return 1 }
fn sign(x: i32) -> i32 where x < 0  { return -1 }

// Each guard runs at most once, in order, and only until one holds.
fn probe(k: i32, ok: bool) -> bool {
    println(f"[guard {k}]")
    return ok
}
fn pick(x: i32) -> i32 where probe(0, x > 10) { return 0 }
fn pick(x: i32) -> i32 where probe(1, x > 5)  { return 1 }
fn pick(x: i32) -> i32 where probe(2, x > 0)  { return 2 }
fn pick(x: i32) -> i32                         { return 3 }

// Methods: the guard reads `self`, and a static and a void group.
class Acc {
    pub var n: i32
    pub fn Acc(self, n: i32) { self.n = n }
    fn get(self, k: i32) -> i32 where k > self.n { return k }
    fn get(self, k: i32) -> i32 { return self.n }
    fn note(self, k: i32) where k == 0 { println("[note] zero") }
    fn note(self, k: i32) { println(f"[note] {k}") }
    static fn kind(k: i32) -> string where k < 0 { return "neg" }
    static fn kind(k: i32) -> string { return "non-neg" }
}

// Passing modes forward as written: `@inout` binds the caller's variable,
// and a MOVE value moves, never copies.
fn bump(@inout n: i32) where n > 0 { n = n + 10 }
fn bump(@inout n: i32) { n = 0 }

pub class Token {
    pub var id: i32
    pub fn Token(self, id: i32) { self.id = id }
    @move
    pub fn Token(self, other: Self) {
        println(f"[move] #{other.id}")
        self.id = other.id
        other.id = -1
    }
    fn op delete(self) {
        if self.id != -1 { println(f"[dtor] live #{self.id}") }
    }
}

fn eat(@move t: Token) -> i32 where t.id > 100 { return t.id * 2 }
fn eat(@move t: Token) -> i32 { return t.id }

fn keep(t: Token) -> i32 where t.id > 100 { return t.id * 2 }
fn keep(t: Token) -> i32 { return t.id }

// A method of a generic record: the dispatcher and its candidates are
// members of the class template, instantiated with it.
class <T> Box {
    pub var v: T
    pub var n: i32
    pub fn Box(self, v: T, n: i32) { self.v = v; self.n = n }
    fn pick(self, x: T, k: i32) -> T where k > self.n { return x }
    fn pick(self, x: T, k: i32) -> T { return self.v }
}

fn main() -> i32 {
    println(f"root {root(16.0)} {root(-1.0)}")
    println(f"divide {safe_divide(10, 2)} {safe_divide(10, 0)} {safe_divide(-4, 2)}")
    println(f"categorize {categorize(500)} {categorize(5)} {categorize(-5)}")
    println(f"first_fallback {first_fallback(7)} {first_fallback(8)}")
    println(f"pos {pos(4)} {pos(-4)}")
    println(f"sign {sign(3)} {sign(0)} {sign(-3)}")
    println(f"pick {pick(7)}")
    println(f"pick {pick(-1)}")

    var a = Acc(5)
    println(f"get {a.get(9)} {a.get(1)}")
    a.note(0)
    a.note(3)
    println(f"kind {Acc::kind(-1)} {Acc::kind(1)}")

    var n: i32 = 1
    bump(&n)
    var z: i32 = -1
    bump(&z)
    println(f"bump {n} {z}")

    var t1 = Token(500)
    println(f"eat {eat(t1)}")
    var t2 = Token(3)
    println(f"keep {keep(t2)}")
    var bi = Box<i32>(7, 3)
    var bf = Box<f64>(1.5, 3)
    println(f"box {bi.pick(1, 5)} {bi.pick(1, 2)} {bf.pick(2.5, 9)}")
    println("[main] end")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
//
// OUT:      root 4 0
// OUT-NEXT: divide 5 0 0
// OUT-NEXT: categorize high positive non-positive
// OUT-NEXT: first_fallback 7 0
// OUT-NEXT: pos 4 0
// OUT-NEXT: sign 1 1 -1
//
// Guard 2 is never evaluated for 7: guard 1 held.
// OUT-NEXT: [guard 0]
// OUT-NEXT: [guard 1]
// OUT-NEXT: pick 1
// OUT-NEXT: [guard 0]
// OUT-NEXT: [guard 1]
// OUT-NEXT: [guard 2]
// OUT-NEXT: pick 3
//
// OUT-NEXT: get 9 5
// OUT-NEXT: [note] zero
// OUT-NEXT: [note] 3
// OUT-NEXT: kind neg non-neg
// OUT-NEXT: bump 11 0
//
// `@move` binds through the dispatcher to the candidate: no move at all.
// OUT-NEXT: eat 1000
// A by-value MOVE parameter moves into the dispatcher and on into the
// candidate, once each; nothing copies, so one live token dies, once.
// OUT-NEXT: [move] #3
// OUT-NEXT: [move] #3
// OUT-NEXT: [dtor] live #3
// OUT-NEXT: keep 3
// OUT-NEXT: box 1 7 2.5
// OUT-NEXT: [main] end
// OUT-NEXT: [dtor] live #500
// OUT-NOT:  [dtor]
