// A C++ function returning `const char*`, used from Kairo (TICKETS: "A C++
// `const char*` in an f-string or passed as `*const i8` is a C++ error").
// It imported as `unsafe *const i8`, spelled `const signed char*`, so
// binding the C++ result to it failed in the C++ step (CL001E "cannot
// initialize a variable of type 'const signed char *' with an rvalue of
// type 'const char *'") -- in an f-string, a `var`, or passed back to C++.
// Now it is `*const c_char`, which is `const char*` exactly.
//
// In an f-string it formats as every pointer does, `<pointee> @ 0x...`: the
// fmt builder has no C-string row yet, so its text is read through C.

import std::io::println
import std::c_char

ffi "c" import "string.h"
ffi "c++" import "chars.h"

fn main() -> i32 {
    var r = 0
    println(f"{greet()}")                       // compiles; the address form
    var unsafe *g = greet()
    unsafe {
        if strlen(g) == 5 { r += 1 }
        if first(g) == 104 { r += 2 }           // 'h': a literal takes c_char
        if count_of(g, 108) == 2 { r += 4 }     // two 'l's
        var buf: [c_char; 8]
        fill(unsafe &buf[0], 120, 3)            // a Kairo array of C chars, filled by C++
        if (strlen(unsafe &buf[0]) == 3) && (buf[0] == 120) && (buf[3] == 0) { r += 8 }
    }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: const char * g = ::greet();
// CXX: char buf[8] {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 15
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: const c_char @ 0x{{[0-9a-f]+}}
