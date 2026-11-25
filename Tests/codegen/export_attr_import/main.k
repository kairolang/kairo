// An `@export` in an imported module reaches the program, once: the C
// function is defined only in the TU of the function it forwards to, so an
// `inline` exported function used from another TU is still one symbol.

import lib

fn main() -> i32 {
    return lib::inl(1)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/k
// RUN: %t.exe; test $? -eq 8
// RUN: %nm %t.exe | %FileCheck %s
// CHECK-DAG: T lib_unused
// CHECK-DAG: T lib_inl
