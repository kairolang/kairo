// A value stored into a part of a local after the whole local was moved
// lives in the moved-from object, so that object's destructor still runs
// at the end of the scope: such a local's moves are not disarmed. The same
// holds for a local whose address is taken anywhere in the body, since a
// pointer can store into it after a move. R counts what it makes and what
// it releases (`~R 0` is a moved-from husk, which owns nothing); every run
// prints `made == released`, with and without -fno-destructive-moves.
//  - one_field / both_fields / on_one_path: `p.b = R(7)` after `take(p)`.
//  - after_maybe: `p.b = R(7)` after a `take(p)` on one path.
//  - through_pointer: a pointer to `p.b` taken before the move, written
//    after it.
//  - filled: `p.b` filled through an `@inout` parameter before the move.
import std::io::println

var made: i32 = 0
var released: i32 = 0

class R {
    var id: i32 = 0
    fn R(self, id: i32) {
        self.id = id
        made += 1
    }
    @move fn R(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) {
        if self.id != 0 {
            released += 1
            println(f"~R {self.id}")
        }
    }
}

class Pair {
    var a: R
    var b: R
    fn Pair(self, x: i32, y: i32) {
        self.a = R(x)
        self.b = R(y)
    }
}

fn take(p: Pair) { }

fn fill(@inout r: R) { r = R(9) }

fn one_field() {
    var p = Pair(1, 2)
    take(p)
    p.b = R(7)
    println("one_field end")
}

fn both_fields() {
    var p = Pair(3, 4)
    take(p)
    p.a = R(8)
    p.b = R(7)
    println("both_fields end")
}

fn on_one_path(c: bool) {
    var p = Pair(5, 6)
    if c {
        take(p)
        p.b = R(7)
    }
    println("on_one_path end")
}

fn after_maybe(c: bool) {
    var p = Pair(15, 16)
    if c {
        take(p)
    }
    p.b = R(7)
    println("after_maybe end")
}

fn through_pointer() {
    var p = Pair(10, 11)
    var *q = &p.b
    take(p)
    *q = R(12)
    println("through_pointer end")
}

fn filled() {
    var p = Pair(13, 14)
    fill(&p.b)
    take(p)
    println("filled end")
}

fn main() -> i32 {
    one_field()
    both_fields()
    on_one_path(true)
    on_one_path(false)
    after_maybe(true)
    after_maybe(false)
    through_pointer()
    filled()
    println(f"made {made} released {released}")
    return if (made == released) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~R 2
// OUT-NEXT: ~R 1
// OUT-NEXT: one_field end
// OUT-NEXT: ~R 7
// OUT-NEXT: ~R 4
// OUT-NEXT: ~R 3
// OUT-NEXT: both_fields end
// OUT-NEXT: ~R 7
// OUT-NEXT: ~R 8
// OUT-NEXT: ~R 6
// OUT-NEXT: ~R 5
// OUT-NEXT: on_one_path end
// OUT-NEXT: ~R 7
// OUT-NEXT: on_one_path end
// OUT-NEXT: ~R 6
// OUT-NEXT: ~R 5
// OUT-NEXT: ~R 16
// OUT-NEXT: ~R 15
// OUT-NEXT: after_maybe end
// OUT-NEXT: ~R 7
// OUT-NEXT: ~R 16
// OUT-NEXT: after_maybe end
// OUT-NEXT: ~R 7
// OUT-NEXT: ~R 15
// OUT-NEXT: ~R 11
// OUT-NEXT: ~R 10
// OUT-NEXT: through_pointer end
// OUT-NEXT: ~R 12
// OUT-NEXT: ~R 14
// OUT-NEXT: ~R 9
// OUT-NEXT: ~R 13
// OUT-NEXT: filled end
// OUT-NEXT: made 24 released 24
// OUT-EMPTY:
