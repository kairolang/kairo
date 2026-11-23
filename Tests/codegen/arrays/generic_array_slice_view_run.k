// A fixed array whose extent or element is a parameter of the enclosing
// generic (`[u8; N]` in `class <eval N: usize>`, `[T; N]` in a generic
// function) views as a slice the way a concrete array does: sliced with a
// range, passed whole to a slice parameter, as a mutable `[T;]` and as a
// `[const T;]`. The view is the slice's `(data, len)` construction with
// the parameter as its length; C++ has no conversion from the C array.

import std::io

fn total(s: [const u8;]) -> usize {
    var t: usize = 0
    for b in s {
        t += b as usize
    }

    return t
}

fn total32(s: [const i32;]) -> i32 {
    var t: i32 = 0
    for b in s {
        t += b
    }

    return t
}

class <eval N: usize> Out {
    var buf: [u8; N]
    var len: usize   = 0

    fn bytes(const self) -> [const u8;] = self.buf[0..self.len]

    fn whole(const self) -> usize = total(self.buf)

    fn fill(self, v: u8) {
        var m: [u8;] = self.buf[0..self.len]
        for var i: usize = 0; i < m.size(); ++i {
            m[i] = v
        }
    }

    fn all(self) -> [u8;] = self.buf
}

class <eval N: usize> Ints {
    var buf: [i32; N]

    fn head(const self, k: usize) -> [const i32;] = self.buf[0..k]

    fn sum(const self) -> i32 = total32(self.buf)
}

fn <T, eval N: usize> first(const a: [T; N], k: usize) -> [const T;] = a[0..k]

fn <eval N: usize> sum_all(const a: [i32; N]) -> i32 = total32(a)

fn <T, eval N: usize> count(const a: [T; N]) -> usize {
    var s: [const T;] = a
    return s.size()
}

fn main() {
    var o: Out<8>
    o.len = 3
    io::println(f"bytes {o.bytes().size()}")
    o.fill(7)
    io::println(f"whole {o.whole()} {o.all().size()}")
    var n: Ints<4>
    n.buf[0] = 1
    n.buf[1] = 2
    n.buf[2] = 3
    n.buf[3] = 4
    io::println(f"ints {n.head(2).size()} {n.head(2)[1]} {n.sum()}")
    var a: [i32; 5] = [10, 20, 30, 40, 50]
    io::println(
        f"fn {first(a, 3).size()} {first(a, 3)[2]} {sum_all(a)} {count(a)}",
    )
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      bytes 3
// CHECK-NEXT: whole 21 8
// CHECK-NEXT: ints 2 2 10
// CHECK-NEXT: fn 3 30 150 5
