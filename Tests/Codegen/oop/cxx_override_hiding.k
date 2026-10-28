// Overrides and same-name methods of IMPORTED C++ classes, and a Kairo
// class overriding a C++ virtual (Inputs/cxx_override_hiding.hh). A C++
// class's lookup is C++'s: a name its own definition declares hides the
// bases' ([class.member.lookup]) unless a `using Base::name;` merges them
// back (MemberLookup, ClassDecl::ffi_usings). Merged instead, `d.h(x)` was
// typed by CBase::h(int) -> i32 while the emitted `d.h(x)` called
// CDerived::h(double).
//
// Each check returns its own code on failure; 0 is a pass.

ffi "c++" import "Inputs/cxx_override_hiding.hh"

class KDerived derives CDerived {
    override fn k(self) -> i32 { return 3 }
}

fn main() -> i32 {
    var d = CDerived()
    if d.k() != 2 { return 1 }                  // the C++ override, on the derived value
    var x: i32 = 1
    if d.f(x) != 20 { return 2 }                // CBase::f is hidden: f(double)
    var z = d.h(x)                              // CDerived::h(double): an f64
    if (z * 2.0) != 5.0 { return 3 }
    if d.g(x) != 100 { return 4 }               // merged by the using-declaration
    var y: f64 = 1.0
    if d.g(y) != 200 { return 5 }
    var kd = KDerived()
    if kd.k() != 3 { return 6 }                 // a Kairo override of a C++ virtual
    var b: *CBase = &kd
    if b->k() != 3 { return 7 }                 // dispatched from C++'s vtable
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
