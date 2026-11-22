// A kcc link that holds Kairo code carries the Kairo runtime, and on ELF its
// mimalloc serves malloc and operator new for the whole program, the C++
// translation units included. inputs/kairo_heap_link/heap.cc asks mimalloc
// whether each block is its own; anchor.k is the Kairo code. Three links:
// heap.cc alone (exactly clang's link: the C library's heap), heap.cc with
// anchor.k in one run, and the two as separate `kcc -c` objects (the ABI
// note marks the Kairo one).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, host-linux
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kcc %S/inputs/kairo_heap_link/heap.cc -o %t.d/pure
// RUN: %t.d/pure | %FileCheck %s --check-prefix=PURE --match-full-lines
// PURE:      malloc c-library
// PURE-NEXT: new c-library

// RUN: %kcc %S/inputs/kairo_heap_link/heap.cc %S/inputs/kairo_heap_link/anchor.k -o %t.d/one
// RUN: %t.d/one | %FileCheck %s --check-prefix=KAIRO --match-full-lines

// RUN: %kcc -c %S/inputs/kairo_heap_link/heap.cc -o %t.d/heap.o
// RUN: %kcc -c %S/inputs/kairo_heap_link/anchor.k -o %t.d/anchor.o
// RUN: %kcc %t.d/heap.o %t.d/anchor.o -o %t.d/two
// RUN: %t.d/two | %FileCheck %s --check-prefix=KAIRO --match-full-lines
// KAIRO:      malloc kairo
// KAIRO-NEXT: new kairo
