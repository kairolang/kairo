// A safe pointer `*T` is never null (pointers.mdx; nullables.mdx, Pointers
// and nullability), so initializing or assigning one with `&null` is an
// error; a pointer that may be absent is `*T?`.
//
// Was XFAIL on the ticket "[Sema] `&null` into a safe pointer `*T` is not
// diagnosed" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). The error is a
// placeholder code (SC001E) until the monthly sweep; every position, the
// note and the fix-it are in null_into_safe_pointer.k.

fn main() -> i32 {
    var p: *i32 = &null
// CHECK: null_safe_pointer.k:[[@LINE-1]]:{{[0-9]+}}: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
    var x: i32 = 1
    var q: *i32 = &x
    q = &null
// CHECK: null_safe_pointer.k:[[@LINE-1]]:{{[0-9]+}}: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
