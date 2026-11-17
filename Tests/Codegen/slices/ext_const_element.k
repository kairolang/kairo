// An extension of the slice type, `extend <T> [T;]`, applies to `[const
// X;]` with T := const X, concrete and in a generic body.

import std::io

extend <T> [T;] {
    fn count(const self) -> usize { return self.len }
    fn head(const self) -> *const T { return &self.data[0] }
    fn count2(const self) -> usize { return self.count() * 2 }
}

fn <U> total(s: [const U;]) -> usize { return s.count() + s.count2() }
fn <U> plain(s: [U;]) -> usize { return s.count() }

fn main() -> i32 {
    var v: [i32] = [4, 5, 6]
    var s: [i32;] = v
    var c: [const i32;] = v
    io::println(f"{s.count()} {c.count()} {*s.head()} {*c.head()} {total(c)} {plain(s)} {plain(c)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: warning
// BUILD-NOT: error
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 3 3 4 4 9 3 3
