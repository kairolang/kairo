import std::io::println
import std::c_char
import lib::*

ffi "c++" import "../chars.h"

fn main() -> i32 {
    var unsafe *g = greet()
    var n = c_len(g)
    var f = first_of(g)                 // T = c_char, instantiated here
    println(f"{n} {f} {shout()}")
    return n as i32
}

// --- lit wiring -----------------------------------------------------------
// lib.k's functions take and return C chars; main passes them a C++ string.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 5
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK: 5 104 33
