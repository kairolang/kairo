// A C++ file that `#include`s a Kairo module of the two-word library
// (string, `[T]`, `{K: V}`, `{T}`, a slice view, std), built and linked by
// kcc on that library.

// --- lit wiring ---
// REQUIRES: newlib, kcc
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc_new -std=c++23 -c %S/Inputs/kcc_include/host.cc -o %t.d/host.o
// RUN: %kcc_new -c %S/Inputs/kcc_include/coll.k -o %t.d/coll.o
// RUN: %kcc_new %t.d/host.o %t.d/coll.o -o %t.d/app
// RUN: %t.d/app
