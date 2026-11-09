// `::exit` (<stdlib.h>) is a header global, so module `exit` is
// spelled `exit_` in C++. A call that reaches the C function from inside
// the module still means the C function: only the namespace moved.

ffi "c" import "stdlib.h"

fn helper() -> i32 { return 42 }

fn main() -> i32 {
    if helper() != 42 { exit(1) }
    return helper()
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d --print-ir 2>&1 || true; } | %FileCheck %s
// RUN: %t.exe; test $? -eq 42
// CHECK: namespace exit_ {
