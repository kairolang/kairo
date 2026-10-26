// The std string methods the docs use (welcome.mdx; examples/http-
// server.mdx): `split` on a delimiter, `length()` on the parts, `trim()` and
// `substring`.
//
// XFAIL: *
// Ticket "[Lib] `string.split` and the other std string methods the docs use
// are missing" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: R025E "no
// member named 'split' in 'string'" (Lib/builtin string has no methods). When
// it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

fn main() -> i32 {
    var input = "3, 4"
    var parts = input.split(",")
    if parts.length() != 2 { return 1 }
    var y = parts[1].trim()
    var head = input.substring(0, 1)
    return (y.length() as i32) * 10 + (head.length() as i32)  // 1 * 10 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
