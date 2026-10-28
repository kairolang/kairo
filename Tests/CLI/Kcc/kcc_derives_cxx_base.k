// A Kairo class deriving a C++ abstract base (Inputs/cxx_base: shape.hh,
// circle.k, shape_main.cpp), crossed both ways. `Square derives Shape`
// overrides the pure virtual `area` and the defaulted `sides`. From C++: a
// Kairo object passed to a C++ function by base reference, and one owned
// by a std::unique_ptr<Shape>, which dispatches into Kairo through the
// vtable and deletes through Shape's virtual destructor. From Kairo:
// `report(s)` hands a Kairo object to C++ by base reference.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/cxx_base/shape_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      C++ report:   8
// CHECK-NEXT: via base ptr: 25
// CHECK-NEXT: Kairo report: 13
// CHECK-EMPTY:
