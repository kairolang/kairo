// The kinds of Kairo declaration a C++ TU uses through an include
// (Inputs/kinds/feat.k): an enum with an underlying type, an ADT built and
// matched by Kairo, a nested module, a struct operator, an extension method
// (a static member of its scope struct), a static field, an @inout
// parameter, a const method, virtual dispatch through a Kairo base, a
// tuple through structured bindings. Built three ways; every build prints
// the same.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// RUN: %kcc %S/Inputs/kinds/use_feat.cc -o %t.d/one 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// QUIET-NOT: {{warning|error}}
// RUN: %t.d/one | %FileCheck %s --match-full-lines
// RUN: %kcc -c %S/Inputs/kinds/use_feat.cc -o %t.d/use.o
// RUN: %kcc -c %S/Inputs/kinds/feat.k -o %t.d/feat.o
// RUN: %kcc %t.d/use.o %t.d/feat.o -o %t.d/sep
// RUN: %t.d/sep | %FileCheck %s --match-full-lines
// RUN: %kairo %S/Inputs/kinds/use_feat.cc -o %t.d/kairo --cache-dir %t.d/ko
// RUN: %t.d/kairo | %FileCheck %s --match-full-lines

// CHECK:      color 4
// CHECK-NEXT: area 16
// CHECK-NEXT: deep 21
// CHECK-NEXT: sum 4 6 dot 11
// CHECK-NEXT: counter id 7 n 2 k 2 made 2
// CHECK-NEXT: who 2 b 5
// CHECK-NEXT: pair 5 10
// CHECK-EMPTY:
