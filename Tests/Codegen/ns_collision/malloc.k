// A module named after a global the build's headers declare
// (`::malloc`, <stdlib.h>) gets the fixed rename `malloc_` for its C++
// namespace, so `namespace malloc {` does not redefine the function.

fn helper() -> i32 { return 42 }

fn main() -> i32 { return helper() }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d --print-ir 2>&1 || true; } | %FileCheck %s
// RUN: %t.exe; test $? -eq 42
// CHECK: namespace malloc_ {
// CHECK: ::malloc_::helper()
