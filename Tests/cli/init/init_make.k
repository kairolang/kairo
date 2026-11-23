// The Makefile --init writes builds the program in each mode and runs it,
// with KAIRO naming the compiler (an installed tree's kairo needs no other
// flags): `make` is the debug build, `make release` the optimized one, `make
// run` the debug build run, and `make clean` removes build/.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: make
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo --init %t/demo > /dev/null
// RUN: make -C %t/demo KAIRO=%kairo_bin
// RUN: test -x %t/demo/build/debug/demo
// RUN: test -d %t/demo/build/cache
// RUN: make -C %t/demo release KAIRO=%kairo_bin
// RUN: %t/demo/build/release/demo | %FileCheck %s
// RUN: make -C %t/demo run KAIRO=%kairo_bin | %FileCheck %s
// CHECK: 3 4 + 2 *  =>  14
// CHECK-NEXT: 1 2 3  =>  error: numbers are left over: an operator is missing
// CHECK-NEXT: 2 x +  =>  error: 'x' is not a number or an operator
// RUN: make -C %t/demo clean
// RUN: test ! -e %t/demo/build
