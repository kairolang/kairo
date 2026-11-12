// Kcc passes --kairo-lib on every link, so a pure C++ program (no .k
// input, no `#include "x.k"`) was linked with builtin, std and the Kairo
// runtime, and on ELF and wasm mimalloc replaced malloc, free and operator
// new for the whole program. A clang drop-in must not change such a
// program. The library is now linked only when the link holds Kairo code:
// a .k input, a C/C++ input that includes a .k, or an object carrying the
// Kairo ABI note (`kcc -c` of host.cc and lib.k, then a link of the two
// objects alone, which only the note can tell apart from pure C++).
// pure.cc returns 3, host.cc 7.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, llvm-nm
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/pure_cxx_link/pure.cc -o %t.d/pure
// RUN: %t.d/pure; test $? -eq 3
// RUN: %nm %t.d/pure | %FileCheck %s --check-prefix=PURE
// PURE-NOT: {{ (mi_|kairo_rt_|kairo_global_)}}

// RUN: %kcc %S/Inputs/pure_cxx_link/host.cc -I %S/Inputs/pure_cxx_link -o %t.d/host
// RUN: %t.d/host; test $? -eq 7
// RUN: %nm %t.d/host | %FileCheck %s --check-prefix=KAIRO
// KAIRO: kairo_

// RUN: %kcc -c %S/Inputs/pure_cxx_link/host.cc -I %S/Inputs/pure_cxx_link -o %t.d/host.o
// RUN: %kcc -c %S/Inputs/pure_cxx_link/lib.k -o %t.d/lib.o
// RUN: %kcc %t.d/host.o %t.d/lib.o -o %t.d/host2
// RUN: %t.d/host2; test $? -eq 7
