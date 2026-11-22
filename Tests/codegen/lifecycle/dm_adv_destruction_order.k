// Live objects are destroyed in reverse declaration order, with or without
// destructive moves (ownership.mdx, Moved-From State): a moved-from local
// prints nothing, the survivors of a partial set of moves keep their
// order, and a rebuilt local sits at its original place. L prints only when
// it holds a value.
import std::io::println

class L {
    var id: i32 = 0
    fn L(self, id: i32) { self.id = id }
    @move fn L(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { if self.id != 0 { println(f"~L {self.id}"); self.id = 0 } }
}
fn take(l: L) { println(f"took {l.id}") }

fn order_all() {
    var a = L(1); var b = L(2); var c = L(3)
    println("all")
}
fn order_mid(x: i32) {
    var a = L(11); var b = L(12); var c = L(13); var d = L(14)
    if x == 1 { take(b) }
    if x == 2 { take(a); take(d) }
    println("mid")
}
fn order_inner(x: i32) {
    var a = L(21)
    {
        var b = L(22)
        var c = L(23)
        if x > 0 { take(b) }
        println("inner")
    }
    var d = L(24)
    if x > 1 { take(a) }
    println("outer")
}
fn order_rebuild() {
    var a = L(31); var b = L(32)
    take(a)
    a = L(33)
    var c = L(34)
    println("rebuilt")
}
fn order_loop() {
    for i in 0..2 {
        var a = L(41 + i * 10); var b = L(42 + i * 10)
        if i == 0 { take(a) }
    }
}
fn order_moved_into() {
    var a = L(51); var b = L(52)
    var c = a
    var d = b
    println("moved into")
}

fn main() -> i32 {
    order_all()
    order_mid(0)
    order_mid(1)
    order_mid(2)
    order_inner(0)
    order_inner(1)
    order_inner(2)
    order_rebuild()
    order_loop()
    order_moved_into()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %t.off.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: all
// OUT-NEXT: ~L 3
// OUT-NEXT: ~L 2
// OUT-NEXT: ~L 1
// OUT-NEXT: mid
// OUT-NEXT: ~L 14
// OUT-NEXT: ~L 13
// OUT-NEXT: ~L 12
// OUT-NEXT: ~L 11
// OUT-NEXT: took 12
// OUT-NEXT: ~L 12
// OUT-NEXT: mid
// OUT-NEXT: ~L 14
// OUT-NEXT: ~L 13
// OUT-NEXT: ~L 11
// OUT-NEXT: took 11
// OUT-NEXT: ~L 11
// OUT-NEXT: took 14
// OUT-NEXT: ~L 14
// OUT-NEXT: mid
// OUT-NEXT: ~L 13
// OUT-NEXT: ~L 12
// OUT-NEXT: inner
// OUT-NEXT: ~L 23
// OUT-NEXT: ~L 22
// OUT-NEXT: outer
// OUT-NEXT: ~L 24
// OUT-NEXT: ~L 21
// OUT-NEXT: took 22
// OUT-NEXT: ~L 22
// OUT-NEXT: inner
// OUT-NEXT: ~L 23
// OUT-NEXT: outer
// OUT-NEXT: ~L 24
// OUT-NEXT: ~L 21
// OUT-NEXT: took 22
// OUT-NEXT: ~L 22
// OUT-NEXT: inner
// OUT-NEXT: ~L 23
// OUT-NEXT: took 21
// OUT-NEXT: ~L 21
// OUT-NEXT: outer
// OUT-NEXT: ~L 24
// OUT-NEXT: took 31
// OUT-NEXT: ~L 31
// OUT-NEXT: rebuilt
// OUT-NEXT: ~L 34
// OUT-NEXT: ~L 32
// OUT-NEXT: ~L 33
// OUT-NEXT: took 41
// OUT-NEXT: ~L 41
// OUT-NEXT: ~L 42
// OUT-NEXT: ~L 52
// OUT-NEXT: ~L 51
// OUT-NEXT: moved into
// OUT-NEXT: ~L 52
// OUT-NEXT: ~L 51
