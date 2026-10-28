// C++ comparing a Kairo class that declares ONLY `op <=>`
// (Inputs/spaceship_only: ord.k, cmp_main.cpp). The other six are derived
// and written into the class (InterfaceEmitter::_derived_cmps): C++20's own
// rewrite of `a < b` to `(a <=> b) < 0` cannot use Kairo's `Ordering`, and
// C++ never derives `==` from a user `<=>`, so without them every line of
// cmp_main.cpp below fails to compile. All six directly, then std::sort
// (`<`), std::find (`==`) and std::set (`std::less`, a duplicate dropped).
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/spaceship_only/cmp_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      111011
// CHECK-NEXT: 123
// CHECK-NEXT: 0
// CHECK-NEXT: 3
// CHECK-EMPTY:
