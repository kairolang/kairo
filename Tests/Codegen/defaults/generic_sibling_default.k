// A generic record's field default that reads another field, as a non-generic
// record's can (classes.mdx, field defaults).
//
// XFAIL: *
// Ticket "[Sema] A generic record's field default cannot read another field
// (SC116E)" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC116E
// "reading another field in the default of a generic record's field is not
// yet supported" (GitHub #95). When it XPASSes, delete the XFAIL -- the run
// below is already the real assertion.

class <T> G {
    pub var a: i32 = 1
    pub var b: i32 = a + 1
}

fn main() -> i32 {
    var g = G<i64>()
    return g.a + g.b                            // 1 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
