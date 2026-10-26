// A C++ class deriving a Kairo abstract class (Inputs/kairo_abstract:
// shape.k, main.cpp) -- the other direction of kcc_derives_cxx_base.k.
// `Shape` declares `virtual fn area(const self) -> f64` with no body, so it
// is pure virtual and the header spells it `= 0`; C++'s `Rect` completes
// it, and a Kairo function taking `*const Shape` dispatches into the C++
// override. A Kairo subclass is called through the same Kairo function.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/kairo_abstract/main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      C++ derived via Kairo: 6
// CHECK-NEXT: C++ derived via C++:   6
// CHECK-NEXT: Kairo derived via Kairo: 20
// CHECK-EMPTY:
