// A C++ container of a destructive Kairo class keeps C++'s rule. Growing a
// `cxx::std::vector<R>` move-constructs every element into the new buffer
// and then destroys the moved-from source, which the `@move` constructor
// left empty; a temporary or a local handed to `push_back` (a C++ `T&&`)
// is moved from and destroyed empty as well. So every value is released
// exactly once, and the destructor also runs on the empty sources: C++
// code never skips one. The counts are the same with destructive moves
// off.
ffi "c++" import "vector"
import std::io::println

var made: i32 = 0
var released: i32 = 0
var empties: i32 = 0

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
        } else {
            empties += 1
        }
    }
}

fn grow() -> i32 {
    var v: cxx::std::vector<R>
    for i in 1..10 {
        v.push_back(R(i))
    }

    var a = R(100)
    v.push_back(a)
    var sum: i32 = 0
    for var k: usize = 0; k < v.size(); ++k {
        sum += v[k].id
    }

    return sum
}

fn main() -> i32 {
    var sum = grow()
    println(f"sum {sum} made {made} released {released}")
    if empties == 0 {
        println("FAIL: no moved-from source was destroyed")
        return 2
    }

    return if (made == released) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --match-full-lines
// CHECK: sum 145 made 10 released 10
