import inputs::counting_arenas::*
// A defaulted `op ==` on a `@set_scoped_allocator(A)` record compares the
// fields the record declares: the two objects have an arena each, and the
// arena is not part of either's value.
import std::io::println

@set_scoped_allocator(Arenas)
struct Point {
    pub var x: i32
    pub var y: i32
    fn op ==(const self, const o: Self) -> bool = default
}

fn main() -> i32 {
    var p = Point { x: 1, y: 2 }
    var q = Point { x: 1, y: 2 }
    var r = Point { x: 1, y: 3 }
    check(p == q, "equal fields, different arenas")
    check(!(p == r), "a field differs")
    check(opened == 3, "an arena each")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
