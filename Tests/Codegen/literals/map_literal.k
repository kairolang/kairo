// A map literal, then a store and a load by key (collections.mdx, Maps).
//
// XFAIL: *
// Ticket "[Lower] Set and map literals have no lowering and ICE"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today it ICEs, under
// --type-check-only too:
// "ListLiteralLowering: map literal has no lowering yet; {K: V} cannot reach
// codegen". Until maps are compiled this should be SC116E, not an ICE. When
// it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

fn main() -> i32 {
    var ages: {string: i32} = {"Alice": 30, "Bob": 25}
    ages["Charlie"] = 35
    return ages["Alice"] + ages["Charlie"]      // 30 + 35
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 65
