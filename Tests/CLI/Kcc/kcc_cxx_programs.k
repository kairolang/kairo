// kcc as plain clang++ and clang: a C++ program using exceptions, RTTI,
// the standard containers and algorithms, std::function, optional and
// variant, linked against the toolchain's libc++, at -O0 and -O2; and a C
// program under -std=c11. No Kairo in sight, and it must still just work.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// RUN: %kcc -Wall %S/Inputs/cxx/features.cc -o %t.d/o0 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// QUIET-NOT: {{warning|error}}
// RUN: %t.d/o0 | %FileCheck %s --match-full-lines
// RUN: %kcc -O2 %S/Inputs/cxx/features.cc -o %t.d/o2 && %t.d/o2 | %FileCheck %s --match-full-lines
// RUN: %kcc -c %S/Inputs/cxx/features.cc -o %t.d/f.o && %kcc %t.d/f.o -o %t.d/fo && %t.d/fo | %FileCheck %s --match-full-lines
// CHECK:      caught boom
// CHECK-NEXT: dyn 1 virt 2
// CHECK-NEXT: typeid 1
// CHECK-NEXT: sorted 1 3 5 9 first a=1 u one
// CHECK-NEXT: fn 42 opt 4 var str
// CHECK-EMPTY:

// RUN: %kcc -std=c11 -Wall %S/Inputs/cxx/hello.c -o %t.d/c && %t.d/c | %FileCheck %s --check-prefix=C
// C: c says 42
