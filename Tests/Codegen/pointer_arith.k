// Offset arithmetic on a safe pointer, in units of the pointee (pointers.mdx,
// Pointer Arithmetic, On safe pointers: `*(p + 1)`, `p = p - 1`).
//
// XFAIL: *
// Ticket "[Sema] Safe pointer arithmetic `*T + int` is SC066E"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today `p + 1` is SC066E "no
// operator '+' for operands '*i32' and 'i32'". When it XPASSes, delete the
// XFAIL -- the run below is already the real assertion.

fn main() -> i32 {
    var arr: [i32; 4] = [10, 20, 30, 40]
    var p: *i32 = &arr[0]
    var second = *(p + 1)
    var q: *i32 = p + 3
    q = q - 1
    return second + *q                          // 20 + 30
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 50
