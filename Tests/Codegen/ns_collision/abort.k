// The rename repeats while the result is still taken. `::abort`
// (<stdlib.h>) takes `abort`, and abort_taken.h declares a global
// `abort_`, so module `abort` is spelled `abort__` in C++.

ffi "c" import "abort_taken.h"

fn helper() -> i32 { return abort_() }

fn main() -> i32 { return helper() }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d --print-ir 2>&1 || true; } | %FileCheck %s
// RUN: %t.exe; test $? -eq 42
// CHECK: namespace abort__ {
// CHECK: ::abort__::helper()
