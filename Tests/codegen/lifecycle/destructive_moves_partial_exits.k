// A field moved out of a local is left out of the local's destruction
// only when no exit of the local's scope comes before the move: a panic
// that propagates out (prop, caught_in, arg_first: an earlier argument
// panics) or a generator dropped at a `yield` (gen) leaves the local with
// the field still in it, so the whole object is destroyed there and the
// husk (`~C 0`) with it on the path that moves. A panic caught inside the
// local's scope does not leave it (caught): the field is left out. Every
// run ends `made == released`, with and without -fno-destructive-moves.
import std::io::println
var made: i32 = 0
var released: i32 = 0
class C {
    var id: i32 = 0
    fn C(self, id: i32) { self.id = id; made += 1 }
    @move fn C(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { if self.id != 0 { released += 1 }; println(f"~C {self.id}") }
}
class Pair {
    var a: C
    var b: C
    fn Pair(self, x: i32, y: i32) { self.a = C(x); self.b = C(y) }
}
fn may(x: i32) panic -> i32 {
    if x > 0 { panic "boom" }
    return x
}
fn eat2(x: i32, c: C) { println(f"eat2 {x} {c.id}") }
fn prop(x: i32) panic {
    var p = Pair(1, 2)
    var v = may(x)
    var y = p.a
    println("prop end")
}
fn caught(x: i32) {
    var p = Pair(3, 4)
    try {
        var v = may(x)
    } catch {
        println("caught")
    }
    var y = p.a
    println("caught end")
}
fn caught_in(x: i32) {
    try {
        var p = Pair(5, 6)
        var v = may(x)
        var y = p.a
    } catch {
        println("caught_in")
    }
}
fn arg_first(x: i32) panic {
    var p = Pair(7, 8)
    eat2(may(x), p.a)
}
fn gen(n: i32) -> yield i32 {
    var p = Pair(9, 10)
    yield 1
    var y = p.a
    yield 2
}
fn main() -> i32 {
    try { prop(1) } catch { println("prop caught") }
    try { prop(0) } catch { }
    caught(1)
    caught_in(1)
    caught_in(0)
    try { arg_first(1) } catch { println("arg caught") }
    try { arg_first(0) } catch { }
    if true {
        var it = gen(1)
        for v in it { if v == 1 { break } }
    }
    if true {
        var it = gen(1)
        for v in it { }
    }
    println(f"made {made} released {released}")
    return if (made == released) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void caught(signed int x) noexcept {
// CXX: +[](void * q) noexcept {
// CXX-LABEL: void caught_in(signed int x) noexcept {
// CXX-NOT: void * q
// CXX: int main() noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe
// OUT:      ~C 2
// OUT-NEXT: ~C 1
// OUT-NEXT: prop caught
// OUT-NEXT: prop end
// OUT-NEXT: ~C 1
// OUT-NEXT: ~C 2
// OUT-NEXT: ~C 0
// OUT-NEXT: caught
// OUT-NEXT: caught end
// OUT-NEXT: ~C 3
// OUT-NEXT: ~C 4
// OUT-NEXT: ~C 6
// OUT-NEXT: ~C 5
// OUT-NEXT: caught_in
// OUT-NEXT: ~C 5
// OUT-NEXT: ~C 6
// OUT-NEXT: ~C 0
// OUT-NEXT: ~C 8
// OUT-NEXT: ~C 7
// OUT-NEXT: arg caught
// OUT-NEXT: eat2 0 7
// OUT-NEXT: ~C 7
// OUT-NEXT: ~C 8
// OUT-NEXT: ~C 0
// OUT-NEXT: ~C 10
// OUT-NEXT: ~C 9
// OUT-NEXT: ~C 9
// OUT-NEXT: ~C 10
// OUT-NEXT: ~C 0
// OUT-NEXT: made 18 released 18
// OUT-EMPTY:
