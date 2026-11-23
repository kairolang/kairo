// -heaplib=libc in a link that holds Kairo code builds a runtime of its own
// (KAIRO_RT_LIBC_HEAP on every runtime source's line), and Kairo's own
// allocations still come from the runtime's mimalloc. Which heap serves C
// malloc and C++ operator new there is kcc_heaplib_libc_kairo.k's question;
// this file asserts only what holds whatever rt/mimalloc.c does with the
// macro: the link succeeds, the program runs, Kairo's block is Kairo's, and
// a default link after it still puts all three on Kairo's heap (the libc
// build does not take the default build's place in the runtime cache).
// blk.k is compiled from its own directory: its module name, and so the
// symbol host.cc's `#include "blk.k"` expects, is blk there.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, host-linux
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kcc -heaplib=libc %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/one
// RUN: %t.d/one | %FileCheck %s --check-prefix=LIBC
// RUN: %kcc -c %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/host.o
// RUN: cd %S/inputs/heaplib && %kcc -c blk.k -o %t.d/blk.o
// RUN: %kcc -heaplib=libc %t.d/host.o %t.d/blk.o -o %t.d/two
// RUN: %t.d/two | %FileCheck %s --check-prefix=LIBC
// LIBC:      malloc {{kairo|foreign}}
// LIBC-NEXT: new {{kairo|foreign}}
// LIBC-NEXT: kairo kairo
// RUN: %kcc %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/dflt
// RUN: %t.d/dflt | %FileCheck %s --check-prefix=DFLT --match-full-lines
// DFLT:      malloc kairo
// DFLT-NEXT: new kairo
// DFLT-NEXT: kairo kairo
