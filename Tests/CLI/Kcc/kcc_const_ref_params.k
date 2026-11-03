// P331 across the C++ boundary: a Kairo function whose string parameter is
// never mutated is declared `const string&` in what `#include "words.k"`
// gives the host, and defined so in words.o, built by a separate run. A
// host that takes its address with the header's signature links against
// the same symbol. 5 + 5 + 6 + 10 + 5.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -c %S/Inputs/const_ref/host.cc -o %t.d/host.o
// RUN: %kcc -c %S/Inputs/const_ref/words.k -o %t.d/words.o
// RUN: %kcc %t.d/host.o %t.d/words.o -o %t.d/main
// RUN: %t.d/main; test $? -eq 31
// RUN: %kcc -E %S/Inputs/const_ref/host.cc -o %t.d/host.ii
// RUN: %FileCheck %s --input-file=%t.d/host.ii
// CHECK-DAG: measure ( const :: builtin :: string :: string & s )
// CHECK-DAG: grow ( :: builtin :: string :: string s )
// CHECK-DAG: add ( const :: builtin :: string :: string & s )
