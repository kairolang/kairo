// A nullable pointer is one pointer wide, with null stored as 0x0
// (nullables.mdx, Pointers and nullability), and a `bool?` is one byte.
//
// XFAIL: *
// Waiting on a niche layout for every `T?` (each stores a presence flag today).
// The pointer half is done: `*T?` uses the null
// niche, so `sizeof *i32? == sizeof *i32` holds. `bool?` still carries a
// presence flag (2 bytes), so the program exits 2 at the `bool?` check.
// When it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

fn main() -> i32 {
    if sizeof *i32? != sizeof *i32 { return 1 }
    if sizeof bool? != 1 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
