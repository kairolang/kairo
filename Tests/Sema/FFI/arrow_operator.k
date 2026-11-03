// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 30
//
// `x->m` on a class with `op ->` reads m from what the operator points to
// ([over.ref]), chained while the result is itself such a class: how a C++
// iterator or smart pointer is read (`it->second`), and what
// operator-overloading.md promises for a Kairo `op ->`. It used to be
// R027E "'->' requires a pointer on its left" for every record.

ffi "c++" import "arrow_operator.h"
ffi "c++" import "map"

class Cell { pub var v: i32 = 4 }

class Box {
    pub var c: Cell
    fn op ->(self) -> *Cell { return &self.c }
}

fn main() -> i32 {
    var m: cxx::std::map<i32, i32>
    m[1] = 10
    var it = m.find(1)
    var h: Handle
    var o: Outer
    var b: Box
    // 10 + 2 + 5 + 3 + 4 + 6 = 30
    return it->second + h->x + h->sum() + o->y + b->v + it->first * 6
}

// DIAG-NOT: error
