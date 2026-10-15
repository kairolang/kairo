import lib::*

fn main() -> i32 {
    var (a, b) = pair()
    var c = pair().1 + b                 // 3.0
    return a + sum((1, 1)) + (c as i32)  // 40 + 2 + 3 == 45
}

// --- lit wiring -----------------------------------------------------------
// lib's header defines Tuple2 under its own guard (no module owns a tuple
// record; every header that reaches one defines it), and main's preamble
// defines it again, unguarded, as a token stream.
//
// REQUIRES: clang
// RUN: rm -rf %t.d %t.h
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --emit-headers=%t.h
// RUN: %t.exe; test $? -eq 45
// RUN: cat %t.h/*.hh %t.h/*/*.hh 2>/dev/null | %FileCheck %s --check-prefix=HDR
// HDR: #ifndef __KAIRO_TUPLE_2
// HDR-NEXT: #define __KAIRO_TUPLE_2
// HDR: struct Tuple2 {
// HDR: #endif
