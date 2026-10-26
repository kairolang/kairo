// A class with a pure virtual method (a `virtual fn` with no body) is
// abstract, and so is a derived class that leaves any of its bases' pure
// methods unoverridden: creating one, by call or initializer, is SC001E at
// the construction, with a note at the method that keeps it abstract.
// Before, Kairo accepted `A()` and clang reported CL001E "allocating an
// object of abstract class type" inside the generated C++. A pointer to
// one, and an object of a class that overrides every pure method, are fine.

class A {
    virtual fn f(self) -> i32
    virtual fn g(self) -> i32
}

class B derives A {
    override fn f(self) -> i32 { return 1 }
}

class C derives B {
    override fn g(self) -> i32 { return 2 }
}

fn main() -> i32 {
    var a  = A()
    var b  = B()
    var a2 = A{}
    var c  = C()
    var pc: *A = &c
    return pc->g()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK:      abstract_construct.k:23:14: error [SC001E]: cannot create an object of abstract class 'A'
// CHECK-NEXT: abstract_construct.k:10:5: note [SC001N]: 'f' is pure virtual: a 'virtual fn' with no body
// CHECK-NEXT: abstract_construct.k:24:14: error [SC001E]: cannot create an object of abstract class 'B'
// CHECK-NEXT: abstract_construct.k:11:5: note [SC001N]: 'A::g' is pure virtual and 'B' does not override it
// CHECK-NEXT: abstract_construct.k:25:14: error [SC001E]: cannot create an object of abstract class 'A'
// CHECK-NEXT: abstract_construct.k:10:5: note [SC001N]: 'f' is pure virtual: a 'virtual fn' with no body
