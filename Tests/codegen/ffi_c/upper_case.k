// `ffi "C"` is C linkage, as `ffi "c"` is (main.k beside this file).
// The parser always matched the word without case; the preprocessor, which
// decides how the header set includes the header, matched only "c", so it
// included c_add.h as C++: the call went to a mangled c_add and the link
// against the C object failed.

ffi "C" import "c_add.h"

fn main() -> i32 {
    return c_add(40, 2)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.k && %kairo %s %S/c_add.c -o %t.exe --cache-dir %t.k
// RUN: %t.exe; test $? -eq 42
