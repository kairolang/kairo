// `derives priv V` / `derives prot V` in the C++: the base stays public,
// so the upcast `*S -> *V` and the checked downcast `as (*S)?` keep working
// from another module (a private C++ base would refuse the first and null
// the second at run time), and the narrowing is written the other way --
// `private: using V::x;` (`protected:` for `prot`) for each name S
// inherits and does not declare, the overloads of `f` under one using; the
// already-protected `g` is narrowed by `priv` and left alone by `prot`.
// Through S those names are then private to C++ too, as Kairo has them
// (AccessCheck::_check_edges); through a `*V` they are V's own.
//
// Each check returns its own code on failure; 0 is a pass.

import Inputs::access_narrow_lib::*

class Q derives P {
    fn Q(self) { }
    fn reach(const self) -> i32 { return self.x + self.g() }
}

fn up(s: *S) -> *V { return s }
fn down(v: *V) -> *S? { return v as (*S)? }

fn main() -> i32 {
    var s = S()
    if s.sum() != 36 { return 1 }
    var *v = up(&s)
    if v->x != 1 { return 2 }                  // V's own member, through a *V
    if v->f() != 10 { return 3 }
    if down(v) == null { return 4 }            // the checked downcast
    if lib_sum(&s) != 11 { return 5 }
    var q = Q()
    if q.reach() != 21 { return 6 }            // prot, from a class deriving P
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s -c --cache-dir %t.d2 --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: class S: public{{ ?}}::{{[A-Za-z0-9_:]+}}::V {
// CXX-NEXT: public: S() noexcept;
// CXX-NEXT: signed int sum() const noexcept;
// CXX-NEXT: private: using{{ ?}}::{{[A-Za-z0-9_:]+}}::V::x;
// CXX-NEXT: using{{ ?}}::{{[A-Za-z0-9_:]+}}::V::f;
// CXX-NEXT: using{{ ?}}::{{[A-Za-z0-9_:]+}}::V::g;
// CXX: class P: public{{ ?}}::{{[A-Za-z0-9_:]+}}::V {
// CXX-NEXT: public: P() noexcept;
// CXX-NEXT: protected: using{{ ?}}::{{[A-Za-z0-9_:]+}}::V::x;
// CXX-NEXT: using{{ ?}}::{{[A-Za-z0-9_:]+}}::V::f;
// CXX-NEXT: using{{ ?}}::{{[A-Za-z0-9_:]+}}::V::k;
//
// A C++ host (Inputs/access_narrow_host.cpp) sees the same: private
// through S, protected through P, public through V, and the conversions.
// REQUIRES: kcc
// RUN: cd %S/Inputs && %kcc access_narrow_host.cpp -o %t.host
// RUN: %t.host
