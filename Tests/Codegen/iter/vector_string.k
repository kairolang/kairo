// `for ... in` over a Kairo vector and over a string (control-flow.mdx, For:
// range and iterator; collections.mdx): a vector yields its elements, a
// string its characters.
//
// XFAIL: *
// Ticket "[Sema/Codegen] `for ... in` over Kairo vectors, sets, maps and
// strings is SC116E" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today:
// SC116E "iterating a vector is not yet supported" and "iterating a string is
// not yet supported". (Sets and maps also need their literals,
// Codegen/literals/.) When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var s = 0
    for x in v { s += x }
    var n = 0
    for c in "abcd" { n += 1 }
    return s * 10 + n                           // 60 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 64
