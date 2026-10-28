// libc's string functions take and return `const char*`, which imports as
// `*const c_char` (std::c_char, C's plain char) and spells `const char*`
// again in the C++: it used to import as `*const i8`, spelled `const signed
// char*`, which no C `char*` binds. A Kairo string's bytes become a C string
// by reinterpreting its `data` (casting.mdx: unrelated pointees need `as
// unsafe *`); the NUL after the last byte is there (primitives.mdx).

import std::io::println
import std::c_char

ffi "c" import "string.h"
ffi "c" import "stdlib.h"
ffi "c" import "stdio.h"

fn main() -> i32 {
    var s = "hi there"
    var n: usize = 0
    var r = 0
    unsafe {
        var unsafe *cs = s.data as unsafe *const c_char
        n = strlen(cs)
        puts(cs)                                        // writes the line itself
        if strcmp(cs, "hi there".data as unsafe *const c_char) == 0 { r += 1 }
        if (strncmp(cs, "hi".data as unsafe *const c_char, 2) == 0) && (cs[3] == 116) { r += 2 }   // 't'
        var unsafe *nope = getenv("KAIRO_N1_SURELY_UNSET_VAR".data as unsafe *const c_char)
        if nope == &null { r += 4 }
    }
    println(f"n {n}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: const char * cs = reinterpret_cast<const char *>(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 7
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      hi there
// OUT-NEXT: n 8
