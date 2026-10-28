// A safe pointer `*T` is never null (pointers.mdx; nullables.mdx, Pointers
// and nullability), so initializing or assigning one with `&null` is an
// error; a pointer that may be absent is `*T?`.
//
// XFAIL: *
// Ticket "[Sema] `&null` into a safe pointer `*T` is not diagnosed"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today both are accepted
// (status.mdx, Not Diagnosed). See also the [Decision] ticket "Things
// Compiler/ does that Stage 1 refuses by design": ~7,000 `*T = &null` sites
// in Compiler/ break when this lands. The code is not decided; the check asks
// for an error at the marked line. When it XPASSes, delete the XFAIL and pin
// the code and message.

fn main() -> i32 {
    var p: *i32 = &null
// CHECK: null_safe_pointer.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    var x: i32 = 1
    var q: *i32 = &x
    q = &null
// CHECK: null_safe_pointer.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
