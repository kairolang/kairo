// An `ffi "c"` Kairo function with a `fn` parameter is callable from C with
// a C function pointer (c-cpp-exposing.mdx: `ffi "c"` gives a Kairo
// function C linkage; closures.mdx: closures share the `fn` pointer type).
// The C side here (caller.c) passes `twice` to kairo_apply.
//
// An `ffi "c"` function's `fn` parameters and result are the raw `unsafe
// fn`: its C declaration takes `int (*)(int)`, so the C caller's
// function pointer is what arrives. Until then a Kairo `fn(A) -> R` was the
// `::__kairo_fn<R(A...)>` class there too, and the program segfaulted.

ffi "c" import "caller.h"

ffi "c" fn kairo_apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

fn main() -> i32 {
    return c_drive()                            // twice(21)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s %S/caller.c -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
