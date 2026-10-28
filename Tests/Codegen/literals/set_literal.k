// A set literal (collections.mdx, Sets): `var primes: {i32} = {2, 3, 5, 7,
// 11}` builds a hash set.
//
// XFAIL: *
// Ticket "[Lower] Set and map literals have no lowering and ICE"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it ICEs, under
// --type-check-only too:
// "ListLiteralLowering: set literal has no lowering yet; {T} cannot reach
// codegen". Until sets are compiled this should be SC116E, not an ICE. When
// it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

fn main() -> i32 {
    var primes: {i32} = {2, 3, 5, 7, 11}
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
