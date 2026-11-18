import std::io

macro text!(x) { stringify!(x) }

fn main() -> i32 {
    io::println(text!($ ` \ $$))
    return 0
}

// A run of characters no token holds is not an error inside a macro
// argument, and stringify! makes text of it as written.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: $ ` \ $$
