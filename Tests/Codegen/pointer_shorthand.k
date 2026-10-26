// G20 (Compiler/Sema/NULLABLE.md 1.7): `var *y = e` end to end. The stars
// are a marker, so the C++ is what `var y = e` gives: each binding is the
// initializer's pointer type, to any depth, and writes through it land in
// the pointee. `var *y? = &x` is the nullable pointer `(*i32)?` (wrapped
// once), and a file-scope `var *gp = &g` is an ordinary global pointer.

import std::io::println

var g = 40
var *gp = &g

fn bump(p: *i32) -> *i32 { *p = *p + 1; return p }

fn main() -> i32 {
    var x = 1
    var *p = &x
    var **pp = &p
    var ***ppp = &pp
    ***ppp = 7
    const *cp = bump(&x)
    var *n? = &x
    if n? { println(f"n {*n}") }
    **pp = **pp + *cp
    println(f"x {x}")
    *gp = *gp + 2
    println(f"g {g}")
    return x - 11
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      signed int * gp ={{.*}}::g);
// CXX:      signed int * p =(& x);
// CXX-NEXT: signed int * * pp =(& p);
// CXX-NEXT: signed int * * * ppp =(& pp);
// CXX:      const signed int * cp =
// CXX:      ::builtin::Nullable<signed int *> n =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 5
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      n 8
// OUT-NEXT: x 16
// OUT-NEXT: g 42
