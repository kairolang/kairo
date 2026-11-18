// main's return value is the process exit code.

import std::io::println

fn main() -> i32 {
    println("before")
    return 7
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: { %wine %t.exe; echo "exit=$?"; } | %FileCheck %s
// CHECK: before
// CHECK: exit=7
