// A pure virtual method, `fn m(self) -> T = virtual` (classes-inheritance.md,
// Abstract classes): no body, implies a vtable slot without a `virtual`
// prefix, overridden in each concrete derived class, dispatched through a
// base pointer.
//
// XFAIL: *
// Waiting on the parser: _parse_fn_body reports S047E "virtual functions
// must be declared with the 'virtual' modifier" on `= virtual` and never
// sets FnBodyKind::Virtual. Everything downstream already handles that body
// kind (TypeUtil's abstractness, ClassLifecycle, InterfaceEmitter's `= 0`).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class Shape {
    fn area(const self) -> i32 = virtual
    fn sides(const self) -> i32 = virtual
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

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
