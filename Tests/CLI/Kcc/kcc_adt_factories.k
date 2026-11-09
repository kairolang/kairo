// A C++ host builds Kairo ADT enum variants through the factories the
// C++-facing text gives each variant (`packet::Frame<int>::Burst(20, 4)`,
// Compiler/Spec/Interop.md#constructing-adt-variants-from-c), not the
// internal tag form `Frame<int>{::__kairo_vt<0>{}, 20, 4}`
// (Inputs/adt_factories): a generic enum at an instance the module
// instantiated and at one it never names, payload and unit variants, a
// non-generic enum with a string payload, and a niche-filled one.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/adt_factories/main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      burst 24
// CHECK-NEXT: code 1005
// CHECK-NEXT: idle -1
// CHECK-NEXT: wide 6000000000
// CHECK-NEXT: assigned 3
// CHECK-NEXT: ok 9
// CHECK-NEXT: err 34
// CHECK-NEXT: nothing -7
// CHECK-NEXT: some 42
// CHECK-NEXT: none 11
// CHECK-EMPTY:
