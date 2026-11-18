// A fixed array where a generic or a witness takes its receiver.
// Each was CL001E in clang: the instance's explicit instantiation spelled
// `int[2] const &` (an array of references), a conformance's witness spelled
// Self as `const int[2] *`, and an extension operator's body rebound its
// receiver as `const int[2] * self`. Every one of them is one
// type-specifier (`__typeof__(int[2])`, or the witness's Self alias).

import std::io

interface Sum {
    fn sum(const self) -> i32
}

interface Bump {
    fn bump(self)
}

extend [i32; 2] impl Sum {
    fn sum(const self) -> i32 { return self[0] + self[1] }
}

extend [i32; 2] impl Bump {
    fn bump(self) { self[0] += 10 }
}

extend [i32; 2] {
    fn op == (const self, const o: [i32; 2]) -> bool {
        return self[0] == o[0] && self[1] == o[1]
    }
}

// A const generic parameter is a `const T&` in C++: with T = [i32; 2] it is
// the caller's array, read in place.
fn <T> first_of(const a: T) -> i32 { return 7 }

fn <T impl Sum> total(const a: T) -> i32 { return a.sum() }

// `@inout` writes the caller's array through the bound.
fn <T impl Bump> poke(@inout a: T) { a.bump() }

fn main() -> i32 {
    var a: [i32; 2] = [1, 2]
    var b: [i32; 2] = [1, 2]
    io::println(f"first {first_of(a)}")
    io::println(f"sum {a.sum()} {total(a)}")
    io::println(f"eq {a == b}")
    poke(&a)
    io::println(f"bumped {a[0]} {total(a)} {a == b}")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      first 7
// CHECK-NEXT: sum 3 3
// CHECK-NEXT: eq true
// CHECK-NEXT: bumped 11 13 false
