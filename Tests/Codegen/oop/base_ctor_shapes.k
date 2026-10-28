// Base initializers, `Base::Base(self, args)` (classes-inheritance.md), in
// the shapes base_ctor_call.k does not cover: the virtual diamond of the
// spec (the most-derived class builds the shared base, an intermediate
// class's call is ignored), a generic base named by its instance, three
// levels with a const field (a constructor CtorInitCheck splits: the base
// goes on the slot constructor), and two bases. Each call becomes the
// constructor's C++ mem-initializer (EmitIR::_mem_inits).
//
// Each check returns its own code on failure; 0 is a pass.

class A {
    pub var value: i32
    fn A(self, v: i32) { self.value = v }
}

class B derives virtual A {
    fn B(self, v: i32) { A::A(self, v + 100) }
}

class C derives virtual A {
    fn C(self, v: i32) { A::A(self, v + 200) }
}

class D derives B, C {
    fn D(self, v: i32) {
        A::A(self, v)          // D initializes the virtual base
        B::B(self, v)
        C::C(self, v)
    }
}

class <T> Box {
    pub var item: T
    fn Box(self, t: T) { self.item = t }
    fn get(self) -> T { return self.item }
}

class IntBox derives Box<i32> {
    fn IntBox(self, n: i32) { Box<i32>::Box(self, n * 2) }
}

class L1 {
    pub var a: i32
    fn L1(self, a: i32) { self.a = a }
}

class L2 derives L1 {
    pub var b: i32
    fn L2(self, a: i32, b: i32) {
        L1::L1(self, a)
        self.b = b
    }
}

class L3 derives L2 {
    pub const c: i32
    fn L3(self, k: i32) {
        L2::L2(self, k, k + 1)
        self.c = k + 2
    }
}

class S1 {
    pub var s: i32
    fn S1(self, s: i32) { self.s = s }
}

class S2 {
    pub var t: i32
    fn S2(self, t: i32) { self.t = t }
}

class M derives S1, S2 {
    fn M(self) {
        S1::S1(self, 5)
        S2::S2(self, 6)
    }
}

fn main() -> i32 {
    var d = D(7)
    if d.value != 7 { return 1 }                // not 107 or 207: B's and C's calls are ignored
    var b = B(1)
    if b.value != 101 { return 2 }              // ... but not when B is the most-derived
    var ib = IntBox(4)
    if ib.get() != 8 { return 3 }
    var l = L3(1)
    if (l.a != 1) || (l.b != 2) || (l.c != 3) { return 4 }
    var m = M()
    if (m.s != 5) || (m.t != 6) { return 5 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
