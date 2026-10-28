// Base initializers across modules (Inputs/base_ctor_lib.k): a derived
// class in this file builds a base declared in another, a plain one and a
// generic one, and reads the base's `prot` fields (AccessCheck: a subclass
// sees them from any file).
//
// Each check returns its own code on failure; 0 is a pass.

import Inputs::base_ctor_lib::*

class Square derives Shape {
    var side: i32
    fn Square(self, side: i32) {
        Shape::Shape(self, 4)
        self.side = side
    }
    fn area(const self) -> i32 { return self.side * self.side + self.sides }
}

class Named derives Holder<i32> {
    fn Named(self, n: i32) { Holder<i32>::Holder(self, n + 1) }
    fn twice(const self) -> i32 { return self.get() * 2 }
}

fn main() -> i32 {
    var s = Square(3)
    if s.count() != 4 { return 1 }
    if s.area() != 13 { return 2 }
    var n = Named(20)
    if n.twice() != 42 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
