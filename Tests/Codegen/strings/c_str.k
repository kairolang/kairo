// A Kairo `string` passed to a C `const char*` parameter through
// `string.c_str()` (c-cpp-calling.mdx, Strings and const char*): O(1), a
// literal's static bytes and an owned string's block both end in a NUL.

ffi "c" import "string.h"

fn main() -> i32 {
    var s = "hello"
    var o = s + ", world"                   // owned: its block keeps the NUL
    o.push_back(33)
    return (strlen(s.c_str()) + strlen(o.c_str())) as i32   // 5 + 13
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 18
