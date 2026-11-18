// kcc accepts every input clang accepts: assembly (.s) and preprocessed
// assembly (.S, run through the C preprocessor first, so -D and #define
// apply) assemble in process and link with a C caller. A plain compile of
// either to an object produces a non-empty object file.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, host-x86_64
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kcc -c %S/Inputs/asm/seven.s -o %t.d/seven.o
// RUN: test -s %t.d/seven.o
// RUN: %kcc -c %S/Inputs/asm/nine.S -o %t.d/nine.o
// RUN: test -s %t.d/nine.o
// RUN: %kcc %S/Inputs/asm/main.c %S/Inputs/asm/seven.s %S/Inputs/asm/nine.S -o %t.d/app
// RUN: %t.d/app
// RUN: %kcc %S/Inputs/asm/main.c %t.d/seven.o %t.d/nine.o -o %t.d/app2
// RUN: %t.d/app2

// The .S is preprocessed: -D reaches it.
// RUN: %kcc -DVAL=2 -c %S/Inputs/asm/nine.S -o %t.d/two.o
// RUN: %kcc %S/Inputs/asm/main.c %t.d/seven.o %t.d/two.o -o %t.d/bad
// RUN: not %t.d/bad
