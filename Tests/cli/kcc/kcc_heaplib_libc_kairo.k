// -heaplib=libc in a link that holds Kairo code: C malloc and C++ operator
// new stay the C library's, while Kairo's own allocations still come from the
// runtime's mimalloc. The driver compiles the runtime with KAIRO_RT_LIBC_HEAP
// under this flag, and the runtime's heap source (Lib/rt/mimalloc.c) leaves
// mimalloc's malloc override off when the macro is defined. blk.k is compiled
// from its own directory so that its module, and its symbol, is blk.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, host-linux
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kcc -heaplib=libc %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/one
// RUN: %t.d/one | %FileCheck %s --match-full-lines
// RUN: %kcc -c %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/host.o
// RUN: cd %S/inputs/heaplib && %kcc -c blk.k -o %t.d/blk.o
// RUN: %kcc -heaplib=libc %t.d/host.o %t.d/blk.o -o %t.d/two
// RUN: %t.d/two | %FileCheck %s --match-full-lines
// CHECK:      malloc foreign
// CHECK-NEXT: new foreign
// CHECK-NEXT: kairo kairo
