// A plain C compile for a WebAssembly target with no OS is clang's and goes
// ahead, with kcc and with kairo alike: only Kairo code (a .k input, an
// `#include "x.k"`, an object carrying Kairo code) needs the C library such a
// target lacks, and only that is refused (P011E).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: printf 'int add(int a, int b) { return a + b; }\n' > %t.d/add.c
// RUN: %kcc --target=wasm32-unknown-unknown -c %t.d/add.c -o %t.d/add.o 2>&1 | %FileCheck %s --allow-empty
// RUN: test -s %t.d/add.o
// RUN: %kairo %t.d/add.c --target=wasm32-unknown-unknown --freestanding -c -o %t.d/add2.o 2>&1 | %FileCheck %s --allow-empty
// RUN: test -s %t.d/add2.o
// CHECK-NOT: P011E
// CHECK-NOT: error
// RUN: printf '#include "%s"\nint f() { return 0; }\n' %s > %t.d/inc.cc
// RUN: { %kcc --target=wasm32-unknown-unknown -c %t.d/inc.cc -o %t.d/inc.o 2>&1 || true; } | %FileCheck %s --check-prefix=INC
// INC: error [P011E]: target 'wasm32-unknown-unknown' is not supported
