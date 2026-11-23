// -heaplib=kairo|libc picks the heap behind C malloc and C++ operator new.
// The default is libc for a link with no Kairo code (clang's link) and kairo
// for one that holds Kairo code. -heaplib=kairo gives a C++-only link the
// runtime's mimalloc and nothing else of the runtime; -heaplib=libc leaves a
// C++-only link as it is. kairo_heap_link/heap.cc asks mimalloc whether each
// block is its own; heaplib/host.cc also allocates from Kairo code (blk.k).
// The flag acts at the link, so a link of `kcc -c` objects honours it too.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, host-linux, llvm-nm
// RUN: rm -rf %t.d && mkdir -p %t.d

// C++ only, no flag and -heaplib=libc: the C library's heap, no runtime.
// RUN: %kcc %S/inputs/kairo_heap_link/heap.cc -o %t.d/dflt
// RUN: %t.d/dflt | %FileCheck %s --check-prefix=LIBC --match-full-lines
// RUN: %kcc -heaplib=libc %S/inputs/kairo_heap_link/heap.cc -o %t.d/libc
// RUN: %t.d/libc | %FileCheck %s --check-prefix=LIBC --match-full-lines
// RUN: %nm %t.d/libc | %FileCheck %s --check-prefix=NORT
// LIBC:      malloc c-library
// LIBC-NEXT: new c-library
// NORT-NOT: {{ [TtDdRrBb] (mi_|kairo_rt_|kairo_global_)}}

// C++ only, -heaplib=kairo: mimalloc serves both, and only the heap object of
// the runtime is linked.
// RUN: %kcc -heaplib=kairo %S/inputs/kairo_heap_link/heap.cc -o %t.d/kairo
// RUN: %t.d/kairo | %FileCheck %s --check-prefix=KAIRO --match-full-lines
// RUN: %nm %t.d/kairo | %FileCheck %s --check-prefix=HEAP
// RUN: %nm %t.d/kairo | %FileCheck %s --check-prefix=HEAPONLY
// RUN: %kcc -c %S/inputs/kairo_heap_link/heap.cc -o %t.d/heap.o
// RUN: %kcc -heaplib=kairo %t.d/heap.o -o %t.d/kairo2
// RUN: %t.d/kairo2 | %FileCheck %s --check-prefix=KAIRO --match-full-lines
// KAIRO:      malloc kairo
// KAIRO-NEXT: new kairo
// HEAP: kairo_rt_notice_mimalloc
// HEAPONLY-NOT: {{ (kairo_global_|kairo_rt_crash|kairo_rt_fmt_)}}

// The kairo driver takes the same flag.
// RUN: %kairo --heaplib=kairo %S/inputs/kairo_heap_link/heap.cc -o %t.d/kdrv
// RUN: %t.d/kdrv | %FileCheck %s --check-prefix=KAIRO --match-full-lines

// Kairo code in the link, no flag and -heaplib=kairo: one heap for all three.
// RUN: %kcc %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/mixed
// RUN: %t.d/mixed | %FileCheck %s --check-prefix=MIXED --match-full-lines
// RUN: %kcc -heaplib=kairo %S/inputs/heaplib/host.cc -I %S/inputs/heaplib -o %t.d/mixed2
// RUN: %t.d/mixed2 | %FileCheck %s --check-prefix=MIXED --match-full-lines
// MIXED:      malloc kairo
// MIXED-NEXT: new kairo
// MIXED-NEXT: kairo kairo

// An unknown value is an error naming the accepted ones.
// RUN: { %kcc -heaplib=jemalloc %S/inputs/kairo_heap_link/heap.cc -o %t.d/bad 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// RUN: { %kairo --heaplib=jemalloc %S/inputs/kairo_heap_link/heap.cc -o %t.d/bad 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'jemalloc' for flag '--heaplib'; accepted: kairo, libc
