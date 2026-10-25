// A Kairo class as a std::unordered_map key (Inputs/eq_hash: point.k,
// map_main.cpp). The C++ side specializes std::hash for point::Point; the
// key comparison is Kairo's own `op ==`, and `+=` on an existing key must
// land on the same entry through it. `!=` is not declared in Kairo: C++20
// rewrites `a != b` as `!(a == b)` against the emitted operator==.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/eq_hash/map_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      size = 2
// CHECK-NEXT: (1,2) = 15
// CHECK-NEXT: (1,2) != (3,4): 1
// CHECK-EMPTY:
