// Spec item 6: MinGW's pthreads are a library of their own, so a program
// that imports pthread.h links winpthread on *-windows-gnu without a
// hand-written `-l pthread`. Other targets' links are unchanged.

ffi "c" import "pthread.h"

fn main() -> i32 {
    var t = pthread_self()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.l
// RUN: %kairo %s --target=x86_64-windows-gnu --print-ld-args --cache-dir %t.d | %FileCheck %s --check-prefix=GNU
// GNU: -lwinpthread
// RUN: %kairo %s --print-ld-args --cache-dir %t.l | %FileCheck %s --check-prefix=HOST
// HOST-NOT: -lwinpthread
