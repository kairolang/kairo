// A program built for x86_64-windows-gnu runs under Wine and writes to stdout.

import std::io::println

fn main() -> i32 {
    println("hello from windows")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s
// CHECK: hello from windows
