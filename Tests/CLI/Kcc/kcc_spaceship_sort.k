// std::sort over Kairo objects (Inputs/spaceship: ver.k, sort_main.cpp).
// Version declares `op <=>` returning Ordering plus every relational
// operator in terms of it; std::sort's `a < b` reaches Kairo's `op <`, and
// the ordering is (major, minor) numerically, so 1.9 sorts before 1.10.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/spaceship/sort_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      0.5
// CHECK-NEXT: 1.9
// CHECK-NEXT: 1.10
// CHECK-NEXT: 2.0
// CHECK-EMPTY:
