// `ffi "c"` imports a header with C linkage. The header set is parsed as
// C++, so a C header without its own `extern "C"` guard is included inside
// `extern "C" { }`. Otherwise `c_add` is declared with C++ linkage, the call
// is emitted against a mangled name, and the link against the C object fails.

ffi "c" import "c_add.h"

fn main() -> i32 {
    return c_add(40, 2)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %clangxx -x c -c %S/c_add.c -o %t.d/c_add.c.o
// RUN: %kairo %s -o %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o %t.d/c_add.c.o -o %t.exe
// RUN: %t.exe; test $? -eq 42
