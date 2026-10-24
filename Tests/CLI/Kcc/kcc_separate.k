// Separate compilation, as with clang: `kcc -c x.cc` treats the .k it
// includes as a header (analysed for the stream, no object), `kcc -c y.k`
// writes y.o and nothing for what y imports, and a link of the objects
// takes builtin, std and the runtime from the toolchain's library, which
// the first link builds into $KAIRO_CACHE_DIR.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// 3 + 4, then hits 2 and 2 + 3; the destructor runs at the C++ scope end.
// RUN: %kcc -c %S/Inputs/use_shapes.cc -o %t.d/x.o
// RUN: %kcc -c %S/Inputs/shapes.k -o %t.d/y.o
// RUN: test "$(ls %t.d)" = "$(printf 'x.o\ny.o')"
// RUN: %kcc %t.d/x.o %t.d/y.o -o %t.d/main
// RUN: %t.d/main > %t.d/main.out; test $? -eq 14
// RUN: %FileCheck %s --input-file=%t.d/main.out
// CHECK:      Tracer()
// CHECK-NEXT: ~Tracer()

// Templates across runs: tmpl.o homes Box<i32> and first<i32>, the .cc
// instantiates Box<long> and first<short> itself (no `extern template` in
// an include). 9 + 1 + 7 + 6.
// RUN: %kcc -c %S/Inputs/use_tmpl.cc -o %t.d/ut.o
// RUN: %kcc -c %S/Inputs/tmpl.k -o %t.d/tmpl.o
// RUN: %kcc %t.d/ut.o %t.d/tmpl.o -o %t.d/tmpl
// RUN: %t.d/tmpl; test $? -eq 23
