// A cast that is an error (a `*void` cast outside `unsafe` is SC023E) does
// not cascade into an overload error for the call it is an argument of:
// exactly one error, no SC063E. The same call inside `unsafe { }` is clean.

ffi "c" import "stdlib.h"

fn main() -> i32 {
    var p: unsafe *const u8
    unsafe { p = malloc(4) as unsafe *const u8 }
    free(p as unsafe *void)
    unsafe { free(p as unsafe *void) }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: poisoned_cast_arg_single_error.k:10:{{[0-9]+}}: error [SC023E]: cast to 'unsafe *void' requires an unsafe context
