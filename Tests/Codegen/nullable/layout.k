// A nullable pointer is one pointer wide, with null stored as 0x0
// (nullables.mdx, Pointers and nullability), and a `bool?` is one byte.
//
// XFAIL: *
// Ticket "[Codegen] Every `T?` stores a presence flag, so `*T?` is wider than
// a pointer and `bool?` wider than a byte" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-26). Today every `T?` is ::builtin::Nullable<T>, its value plus a
// presence flag, so `sizeof *i32?` is 16 and the program exits 1 (status.mdx,
// Nullables: "Not yet"). When it XPASSes, delete the XFAIL -- the run below
// is already the real assertion.

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
