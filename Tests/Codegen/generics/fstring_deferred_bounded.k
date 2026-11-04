// An f-string hole on a bounded parameter's value whose bounds grant no
// string (`<T impl Sized>`, Sized with no `repr` / `op as`) is formatted per
// instance: the body is one C++ template, and the put is picked at each
// instance from the value's type (LowerTargets::fmt_dyn). It used to be
// R051E "formatting a 'T' needs a bound that declares ...". A bound that
// DOES grant `repr` still goes through its witness.

import std::io::println

pub interface Sized {
    fn size(const self) -> i32
}

extend i32 impl Sized {
    fn size(const self) -> i32 { return 4 }
}

pub class Box {
    pub var v: i32
    fn Box(self, v: i32) { self.v = v }
    fn size(const self) -> i32 { return 8 }
    pub fn repr(const self) -> string = "Box"
}
extend Box impl Sized { }

fn <T impl Sized> show(x: T) -> string {
    return f"[{x}] {x.size()}"
}

fn main() -> i32 {
    println(show(7))
    println(show(Box(1)))
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: [7] 4
// CHECK-NEXT: [Box] 8
