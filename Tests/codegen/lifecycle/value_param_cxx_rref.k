// A generic body that hands a value to a C++ `T&&` parameter
// (`std::vector<T>::push_back`) calls a function clang picks per instance:
// nothing is known of its parameter where the body is checked. The moved
// place keeps whatever destroys it, so the move goes to the callee as it
// is, with no object of the call's own in between: an object of the call's
// own would cost one more move per `push_back` (ten here). Every value is
// still released exactly once.
ffi "c++" import "vector"
import std::io::println

var made: i32 = 0
var moved: i32 = 0
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
        moved += 1
    }

    fn op finally(self) {
        if self.id != 0 {
            released += 1
        }
    }
}

fn <T> push_two(a: T, b: T, @inout out: cxx::std::vector<T>) {
    out.push_back(a)
    out.push_back(b)
}

fn run() -> i32 {
    var out: cxx::std::vector<R>
    out.reserve(8)
    var before = moved
    push_two<R>(R(1), R(2), &out)
    push_two<R>(R(3), R(4), &out)
    var pushed = moved - before
    var sum: i32 = 0
    for var k: usize = 0; k < out.size(); ++k {
        sum += out[k].id
    }

    println(f"sum {sum} moves {pushed}")
    return sum
}

fn main() -> i32 {
    run()
    println(f"made {made} released {released}")
    return if (made == released) => (0) else => 1
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --match-full-lines

// CHECK:      sum 10 moves 6
// CHECK-NEXT: made 4 released 4
