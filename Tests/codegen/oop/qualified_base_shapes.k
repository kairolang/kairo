// `Base::m(self)` -- the only way to reach a base's version of a method
// (classes-inheritance.md, Calling base class methods: no `super`) -- in
// the shapes qualified_base_method.k does not cover. The object binds the
// base's `self` as C++'s implicit object does, by reference, and the call
// is written `obj.Base::m()`, the non-virtual call the qualified name asks
// for.
//
// Each check returns its own code on failure; 0 is a pass.

class A {
    virtual fn who(self) -> i32 { return 1 }
    fn plain(const self) -> i32 { return 10 }
}

class B derives A {
    override fn who(self) -> i32 { return 2 }
}

class C derives B {
    override fn who(self) -> i32 { return A::who(self) * 100 + B::who(self) * 10 + 3 }
    fn base_plain(self) -> i32 { return A::plain(self) }
}

// The diamond of classes-inheritance.md: each branch named explicitly.
class Root { fn method(self) -> i32 { return 1 } }
class Left derives Root { fn method(self) -> i32 { return 2 } }
class Right derives Root { fn method(self) -> i32 { return 3 } }
class Join derives Left, Right {
    fn method(self) -> i32 { return Left::method(self) * 10 + Right::method(self) }
}

class <T> Box {
    pub var item: T
    fn get(self) -> T { return self.item }
}

class IntBox derives Box<i32> {
    fn twice(self) -> i32 { return Box<i32>::get(self) * 2 }
}

fn make() -> C { return C() }

fn main() -> i32 {
    var c = C()
    if c.who() != 123 { return 1 }              // A's and B's versions from C's override
    var a: *A = &c
    if a->who() != 123 { return 2 }             // and still virtual through the base pointer
    if c.base_plain() != 10 { return 3 }        // a const method, two levels up
    if A::who(c) != 1 { return 4 }              // from outside the class: non-virtual
    if B::who(c) != 2 { return 5 }
    if A::plain(make()) != 10 { return 6 }      // a temporary object
    var j = Join()
    if j.method() != 23 { return 7 }
    var ib = IntBox()
    ib.item = 21
    if ib.twice() != 42 { return 8 }            // a generic base, by its instance
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
