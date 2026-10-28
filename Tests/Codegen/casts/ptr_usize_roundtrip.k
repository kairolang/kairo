// An address out and back in (casting.mdx, Integer to pointer): `p as
// usize` is safe, `n as unsafe *T` needs an unsafe block, and the pointer
// that comes back reads and writes the original object. Also from a generic
// `*T`, whose instance is a C++ template body: the reinterpret_cast is
// written once and must hold for every T, a record included.

import std::io::println

class Node { pub var v: i32 = 10 }

fn <T> addr(p: *T) -> usize { return p as usize }

fn <T> same(a: *T, b: *T) -> bool { return (a as usize) == (b as usize) }

fn main() -> i32 {
    var x: i32 = 41
    var n = Node()
    var m = Node()
    var r = 0

    var ax = addr(&x)
    var an = addr(&n)
    if ax == (&x as usize) { r += 1 }
    if an == (&n as usize) { r += 2 }
    if same(&x, &x) { r += 4 }
    if !same(&n, &m) { r += 8 }

    unsafe {
        var unsafe *back = ax as unsafe *i32
        *back = *back + 1                   // writes x through the rebuilt pointer
        var unsafe *nb = an as unsafe *Node
        nb->v = 20
    }
    if x == 42 { r += 16 }
    if n.v == 20 { r += 32 }
    println(f"x {x} v {n.v}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T> decltype(sizeof(0)) addr(T * p) noexcept {
// CXX-NEXT: return reinterpret_cast<decltype(sizeof(0))>(p);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 63
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: x 42 v 20
