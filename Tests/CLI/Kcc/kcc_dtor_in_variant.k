// Kairo classes with an `op delete` as std::variant alternatives
// (Inputs/variant_dtor: shapes2.k, variant_main.cpp). std::visit reads
// their fields; `emplace` of the other alternative destroys the held Cat
// exactly once, and the variant's own destruction destroys the Dog: each
// Kairo destructor runs once, where C++ says it does.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/variant_dtor/variant_main.cpp -o %t.d/app 2>/dev/null
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      cat with 9 lives
// CHECK-NEXT:   ~Cat
// CHECK-NEXT: dog with 3 tricks
// CHECK-NEXT:   ~Dog
// CHECK-NEXT: done
// CHECK-EMPTY:
