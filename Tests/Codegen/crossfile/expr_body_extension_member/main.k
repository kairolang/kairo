// An expression-bodied extension member whose body is a lone literal, in a
// file that has no trailing newline, is emitted correctly when the type, the
// interface and the extension are in three other files and a generic in a
// fourth calls it.

import m
import n
import e

fn main() -> i32 {
    return n::get(m::M())
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe; test $? -eq 7
