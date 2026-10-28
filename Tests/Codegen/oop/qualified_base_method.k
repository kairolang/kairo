// Calling a base's version of a method by qualified name, `Base::m(self)`
// (classes-inheritance.md, Calling base class methods: there is no `super`),
// from an override that extends it and from a hiding method.
//
// Formerly an expected failure: `self` of type Derived was not viable for
// Base's `self` (SC063E "cannot convert argument of type 'Derived' to
// parameter 'self' of type 'Base'"). The object now binds as C++'s implicit
// object does, by reference (derived-to-base), and the call is written
// `obj.Base::m()`: non-virtual, as the qualified name asks.
// qualified_base_shapes.k has more shapes.

class Base {
    virtual fn cost(self) -> i32 { return 10 }
    fn name(self) -> i32 { return 1 }
}

class Derived derives Base {
    override fn cost(self) -> i32 { return Base::cost(self) + 5 }
    fn label(self) -> i32 { return Base::name(self) + 1 }
}

fn main() -> i32 {
    var d = Derived()
    var b: *Base = &d
    return b->cost() + d.label()                // 15 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 17
