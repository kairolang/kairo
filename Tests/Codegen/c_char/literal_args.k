// P301: a string LITERAL passed to a C or C++ `const char *` parameter is
// the C string itself (c-cpp-calling.mdx, Strings and const char*): its
// static, NUL-terminated bytes, with no `string` made. So is one passed to
// `const unsigned char *` (`*const u8`) and to C's `...` tail. A string
// that is not a literal still goes through `.c_str()`.

ffi "c" import "string.h"
ffi "c" import "stdlib.h"
ffi "c" import "stdio.h"
ffi "c" import "literal_args.h"

fn main() -> i32 {
    var r = 0
    if strlen("abc") == 3 { r += 1 }
    if getenv("KAIRO_P301_SURELY_UNSET_VAR") == &null { r += 2 }
    if strcmp("same", "same") == 0 { r += 4 }
    if count_c("hello" "!") == 6 { r += 8 }          // adjacent parts are one literal
    if first_u("\u00e9") == 0xC3 { r += 16 }         // UTF-8 bytes, as written
    var s = "owned"
    s += "!"
    if count_c(s.c_str()) == 6 { r += 32 }
    printf("%s %d|%s\n", "lit", 5, s.c_str())
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 63
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// OUT: lit 5|owned!
