// Passing a slice literal to a function that STORES the slice: the literal's
// storage ends with the statement, so the stored slice would dangle
// (collections.mdx, How long a slice literal's storage lives). Tether reports
// it at the call.
//
// XFAIL: *
// Ticket "[Sema/Tether] A slice literal passed to a function that stores it
// is not diagnosed" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it
// compiles, and the stored slice dangles (status.mdx, Not Diagnosed; waits on
// Tether). The code is not decided; the check asks for an error at the marked
// line. When it XPASSes, delete the XFAIL and pin the code and message.

var kept: [i32;] = [0]

fn keep(s: [i32;]) {
    kept = s
}

fn main() -> i32 {
    keep([1, 2, 3])
// CHECK: slice_literal_stored.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
