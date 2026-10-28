// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// A closure parameter with a default (closures.md, Default Parameters:
// "matching the behavior of regular functions").
//
// XFAIL: *
// Waiting on call typing honouring a closure's defaults: `f(1)` is SC099E
// "'fn (i32, i32) -> i32' takes 2 argument(s), 1 given" -- the default is
// dropped from the closure's function type. Then on lambda emission
// (closures.k).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

fn main() -> i32 {
    var f = fn (a: i32, b: i32 = 2) -> i32 { return a + b }
    return f(1) + f(1, 5)                      // 3 + 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
