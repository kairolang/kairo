// A Kairo `string` passed to a C `const char*` parameter through
// `string.c_str()` (c-cpp-calling.mdx, Strings and const char*: "A
// `string.c_str()` method is planned").
//
// XFAIL: *
// Ticket "[Lib/Sema] A Kairo `string` cannot reach a C `const char*`: no
// `string.c_str()`" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: R025E
// "no member named 'c_str' in 'string'". (A string's `data` is `*const u8`,
// and `*u8` to `*i8` is neither implicit nor a safe cast.) When it XPASSes,
// delete the XFAIL -- the run below is already the real assertion.

ffi "c" import "string.h"

fn main() -> i32 {
    var s = "hello"
    return strlen(s.c_str()) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
