// A C++ `new` / `delete` of a Kairo record takes its storage from Kairo's
// global allocator, through the class-scope operators the C++-facing text
// gives every class, struct and ADT enum (Compiler/Spec/Codegen.md#c-allocation-operators).
// Inputs/cxx_alloc_ops/shapes.k sets a counting global allocator, so every
// block C++ news or deletes shows up in its counts, with the size and
// alignment it was asked for: a single object (sizeof, alignof), an array
// (cookie included, at least 16-aligned), an over-aligned struct (the
// align_val_t forms, 64), a generic class at an instance the module names
// (extern template in the C++ view) and at one it never does, an ADT enum,
// `new (std::nothrow)`, and placement new (no allocation). Then the two
// crossings: a Kairo create freed by a C++ delete, and a C++ new freed by
// a Kairo destroy, each one allocation and one free of the same block size.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/cxx_alloc_ops/main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      start 0 0
// CHECK-NEXT: sum 7
// CHECK-NEXT: new-point allocs=1 frees=0 size=8 align=4
// CHECK-NEXT: delete-point allocs=1 frees=1 size=8 align=4
// CHECK-NEXT: new-array allocs=2 frees=1 size=32 align=16
// CHECK-NEXT: delete-array allocs=2 frees=2 size=32 align=16
// CHECK-NEXT: wide-aligned 1
// CHECK-NEXT: new-wide allocs=3 frees=2 size=64 align=64
// CHECK-NEXT: delete-wide allocs=3 frees=3 size=64 align=64
// CHECK-NEXT: new-wide-array allocs=4 frees=3 size=192 align=64
// CHECK-NEXT: delete-wide-array allocs=4 frees=4 size=192 align=64
// CHECK-NEXT: box 5
// CHECK-NEXT: boxl 6
// CHECK-NEXT: box allocs=6 frees=6 size=8 align=8
// CHECK-NEXT: area 16
// CHECK-NEXT: adt allocs=7 frees=7 size=8 align=4
// CHECK-NEXT: nothrow allocs=8 frees=7 size=16 align=8
// CHECK-NEXT: placement 11
// CHECK-NEXT: placement allocs=8 frees=8 size=16 align=8
// CHECK-NEXT: kairo-made 18
// CHECK-NEXT: cxx-delete-of-create allocs=9 frees=9 size=8 align=4
// CHECK-NEXT: destroy-of-cxx-new allocs=10 frees=10 size=8 align=4
// CHECK-EMPTY:
