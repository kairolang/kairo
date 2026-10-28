// A tuple literal converts element-wise into a tuple type with nullable
// elements: `i32 -> i32?` is implicit for each element (nullables.mdx: a
// value converts into a `T?` anywhere a `T?` is expected).
//
// XFAIL: *
// Ticket "[Sema] A tuple literal does not convert element-wise into a
// tuple with nullable elements" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-25). Today `(5, 1)` is SC028E "cannot convert '(i32, i32)' to
// '(i32?, i32)'" (`(null, 1)` is accepted: the literal takes the expected
// type there). When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

fn main() -> i32 {
    var t: (i32?, i32) = (5, 1)
    var u: (i32?, i32) = (null, 2)
    return (t.0 ?? 0) + t.1 + (u.0 ?? 10) + u.1 // 5 + 1 + 10 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 18
