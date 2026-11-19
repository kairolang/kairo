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
// RUN: rm -f %t.exe
// RUN: %kairo %s %S/c_add.c -o %t.exe --cache-dir %t.d/k
// The C file is compiled and linked by the same kairo invocation.
// RUN: %t.exe; test $? -eq 42

// The same program with the C source handed to kairo itself: compiled by the
// pinned clang on kairo's target and roots, and linked in one step.
// RUN: rm -rf %t.k2 && %kairo %s %S/c_add.c -o %t.native.exe --cache-dir %t.k2
// RUN: %t.native.exe; test $? -eq 42
