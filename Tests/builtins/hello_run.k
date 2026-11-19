// The two-word library links and runs a program: a string literal is built
// from its read-only object and std::io writes its bytes, unoptimized and
// optimized.

import std::io

fn main() -> i32 {
    io::println("hello, world")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: hello, world
