// across the C++ boundary: an exported (`pub`) function keeps the written
// by-value form for a parameter of a COPY, non-trivially-copyable record,
// both in what `#include "words.k"` gives the host and in words.o, built
// by a separate run; the inferred `const T&` applies only to functions
// that stay in their file. A host that takes its address with the
// header's signature links against the same symbol. 5 + 5 + 6 + 10 + 5.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -c %S/inputs/const_ref/host.cc -o %t.d/host.o
// RUN: %kcc -c %S/inputs/const_ref/words.k -o %t.d/words.o
// RUN: %kcc %t.d/host.o %t.d/words.o -o %t.d/main
// RUN: %t.d/main; test $? -eq 31
// RUN: %kcc -E %S/inputs/const_ref/host.cc -o %t.d/host.ii
// RUN: %FileCheck %s --input-file=%t.d/host.ii
// CHECK-DAG: measure ( :: words :: Text s )
// CHECK-DAG: grow ( :: words :: Text s )
// CHECK-DAG: add ( :: words :: Text s )
