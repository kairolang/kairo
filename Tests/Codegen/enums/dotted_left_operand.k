// The shorthand `.V` as the LEFT operand of `==` / `!=` takes its enum type
// from the other operand, as it does on the right (enums-plain.mdx; pattern-
// matching.mdx).
//
// XFAIL: *
// Ticket "[Sema] `.V` as the left operand of `==` / `!=` is SC123E"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today `.North == d` is SC123E
// "'.North' names an enum variant, but nothing here gives it an enum type" --
// the left operand is typed before the right one gives it an expected type
// (GitHub #83). `d == .North` works. When it XPASSes, delete the XFAIL -- the
// run below is already the real assertion.

enum Dir { North, South }

fn main() -> i32 {
    var d = Dir::North
    var r = 0
    if .North == d { r += 1 }
    if .South != d { r += 2 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
