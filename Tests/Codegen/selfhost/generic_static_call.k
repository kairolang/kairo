// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// A static method called through a generic class instance,
// `Box<i32>::zero()` (classes.md, Static Members + Generic Classes).
//
// XFAIL: *
// Waiting on codegen spelling the instance in the qualifier: Kairo accepts
// it and clang rejects the emitted call, CL001E "use of class template
// 'Box' requires template arguments".
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class <T> Box {
    static fn zero() -> i32 { return 7 }
}

fn main() -> i32 {
    return Box<i32>::zero()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
