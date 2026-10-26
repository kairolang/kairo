// A pure virtual method is a `virtual fn` with no body (classes-
// inheritance.mdx, Abstract classes): a vtable slot with no definition,
// spelled `= 0` in C++, overridden in each concrete derived class and
// dispatched through a base pointer. `= virtual`, the old spelling, is
// S047E (Tests/Parser/Grammar/pure_virtual_spelling.k); constructing the
// abstract class is SC001E (Tests/Sema/Check/abstract_construct.k).

class Shape {
    virtual fn area(const self) -> i32
    virtual fn sides(const self) -> i32
}

class Square derives Shape {
    var s: i32
    fn Square(self, s: i32) { self.s = s }
    override fn area(const self) -> i32 { return self.s * self.s }
    override fn sides(const self) -> i32 { return 4 }
}

class Tri derives Shape {
    override fn area(const self) -> i32 { return 6 }
    override fn sides(const self) -> i32 { return 3 }
}

fn total(a: *const Shape, b: *const Shape) -> i32 {
    return a->area() + b->area() + a->sides() * b->sides()
}

fn main() -> i32 {
    var sq = Square(2)
    var tr = Tri()
    return total(&sq, &tr)                      // 4 + 6 + 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: %kairo %s --print-ir 2>&1 | %FileCheck %s --check-prefix=IR
// IR:      class Shape {
// IR-NEXT:     public: virtual signed int area() const = 0;
// IR-NEXT:     virtual signed int sides() const = 0;
// IR-NEXT: };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
