// `char`, `signed char` and `unsigned char` are three C++ types, so a header
// overloading on them is three overloads to Kairo: c_char, i8 and u8. The
// importer read plain `char` by width and sign alone, so it was i8 (x86) or
// u8 (AArch64 Linux) and collided with one of the other two.

import std::io::println
import std::c_char

ffi "c++" import "chars.h"

fn main() -> i32 {
    var c: c_char = 65
    var s: i8 = 65
    var u: u8 = 65
    var a = which(c)
    var b = which(s)
    var d = which(u)
    println(f"{a} {b} {d} {which(1i8)} {which(1u8)}")
    return a * 100 + b * 10 + d
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: char c = 65;
// CXX-NEXT: signed char s = 65;
// CXX-NEXT: unsigned char u = 65;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 123
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: 1 2 3 2 3
