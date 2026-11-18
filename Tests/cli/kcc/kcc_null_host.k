// A C++ host spells the library type behind `T?` as ::builtin::Null<T>
// (inputs/null_host: cells.k, null_main.cpp). The host builds both cases
// itself, passes one to Kairo, and reads the ones Kairo returns; the
// static_asserts pin that a Kairo `i32?` / `Cell?` IS that type.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/inputs/null_host/null_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      a null 1, b 4
// CHECK-NEXT: or_zero 0 4
// CHECK-NEXT: some 6, none null 1
// CHECK-NEXT: cell 3, d null 1
// CHECK-EMPTY:
