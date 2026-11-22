// A closure that moves its own capture out (its first use of the capture
// is itself a move) still takes the local in by a disarmed move where it
// is built; the move inside the body empties the closure's member, which
// is destroyed with the closure (the `~R 0`). R counts what it makes and
// releases; the run ends `made == released`.
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
        }
        println(f"~R {self.id}")
    }
}

fn eat(r: R) { }

fn eaten() {
    var a = R(1)
    var f = fn () { eat(a) }
    f()
    println("eaten end")
}

fn bound() {
    var a = R(2)
    var f = fn () -> i32 {
        var b = a
        return b.id
    }
    println(f"bound {f()}")
}

fn main() -> i32 {
    eaten()
    bound()
    println(f"made {made} released {released}")
    return if (made == released) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void eaten() noexcept {
// CXX: [a = static_cast< ::{{.*}}::R &&>(__k_s_a.v)]

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~R 1
// OUT-NEXT: eaten end
// OUT-NEXT: ~R 0
// OUT-NEXT: ~R 2
// OUT-NEXT: bound 2
// OUT-NEXT: ~R 0
// OUT-NEXT: made 2 released 2
// OUT-EMPTY:
