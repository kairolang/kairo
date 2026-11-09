// @cxx::new / @cxx::delete (c-cpp-memory.mdx, "Memory that belongs to C++"):
// C++'s own `new T(args)` / `new T[n]` / `delete p` / `delete[] p`, so memory
// crosses the boundary in both directions -- made by Kairo and freed by C++,
// made by C++ and freed by Kairo -- single objects and arrays, through kcc's
// `#include "mem.k"`. Inputs/cxx_new_delete: gadget.h (a C++ type with a
// live count), mem.k (the Kairo side), main.cpp (the C++ side).

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/cxx_new_delete && %kcc main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      start live=0
// CHECK-NEXT: v 5
// CHECK-NEXT: kairo-new live=1
// CHECK-NEXT: cxx-delete live=0
// CHECK-NEXT: cxx-new live=1
// CHECK-NEXT: kairo-delete live=0
// CHECK-NEXT: arr 1 1 1
// CHECK-NEXT: kairo-new-array live=3
// CHECK-NEXT: cxx-delete-array live=0
// CHECK-NEXT: cxx-new-array live=2
// CHECK-NEXT: kairo-delete-array live=0
// CHECK-NEXT: ints 10 20 30 40
// CHECK-NEXT: ints-cxx-delete live=0
// CHECK-NEXT: sum 6
// CHECK-NEXT: ints-kairo-delete live=0
// CHECK-EMPTY:
//
// The Kairo side, as C++ receives it.
// RUN: cd %S/Inputs/cxx_new_delete && %kairo mem.k -c -o %t.d/mem.o --cache-dir %t.d/c --print-ir 2>/dev/null > %t.d/mem.ir
// RUN: %FileCheck %s --check-prefix=IR < %t.d/mem.ir
// IR: (new{{ ?}}::Gadget( ::Gadget(v)))
// IR: delete g;
// IR: (new{{ ?}}::Gadget[n])
// IR: delete[] g;
