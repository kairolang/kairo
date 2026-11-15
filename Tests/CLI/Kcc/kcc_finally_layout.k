// A local `finally()` ends is stored as the member of a union
// (Compiler/Spec/Lowering.md#union-storage-locals): its size, its alignment
// and its address are those of a plain `T x`, and its declared type is T.
// The C++ host includes the Kairo file and asserts it on the helpers that
// Kairo file brings into the TU.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/finally_layout/layout_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK: 6 6
// CHECK-EMPTY:
