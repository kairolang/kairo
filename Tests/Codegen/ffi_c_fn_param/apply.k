// An `ffi "c"` Kairo function with a `fn` parameter is callable from C with
// a C function pointer (c-cpp-exposing.mdx: `ffi "c"` gives a Kairo
// function C linkage; closures.mdx: closures share the `fn` pointer type).
// The C side here (caller.c) passes `twice` to kairo_apply.
//
// XFAIL: *
// Ticket "[Codegen] `ffi \"c\"` Kairo function with a `fn` parameter"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Since cdcc738f a Kairo
// `fn(A) -> R` parameter is `::__kairo_fn<R(A...)>`, a class, also under
// `extern "C"`: the C caller's raw function pointer is read as that class,
// so the program segfaults. Passes once an `ffi "c"` function's
// `fn` parameters (and return) are spelled `R(*)(A...)` and converted at the
// boundary. When it XPASSes, delete the XFAIL -- the run below is already
// the real assertion.

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
