// Several modules and several C++ TUs: y.k imports z.k, and two .cc files
// both include y.k. One run builds and links everything; separate runs
// need every object, as with clang, and a missing one is an undefined
// symbol, never a silent rebuild. Including one module from two TUs
// defines nothing twice. use1 = 10 + 1, main = 11 + 21.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d/one %t.d/sep && cd %t.d/one

// RUN: %kcc %S/Inputs/multi/m1.cc %S/Inputs/multi/m2.cc -o %t.d/one/app && %t.d/one/app; test $? -eq 32
// RUN: test -z "$(ls %t.d/one | grep -v '^app$')"

// RUN: cd %t.d/sep && %kcc -c %S/Inputs/multi/m1.cc %S/Inputs/multi/m2.cc
// RUN: cd %t.d/sep && %kcc -c %S/Inputs/multi/y.k
// RUN: test "$(ls %t.d/sep)" = "$(printf 'm1.o\nm2.o\ny.o')"
// RUN: cd %t.d/sep && { %kcc m1.o m2.o y.o -o app 2>&1 || true; } | %FileCheck %s --check-prefix=NOZ
// NOZ: error [L001E]: undefined symbol: z::base(int)
// RUN: cd %t.d/sep && %kcc -c %S/Inputs/multi/z.k && %kcc m1.o m2.o y.o z.o -o app && ./app; test $? -eq 32

// The same objects in any order.
// RUN: cd %t.d/sep && %kcc z.o y.o m2.o m1.o -o app2 && ./app2; test $? -eq 32
