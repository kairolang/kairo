import std::io::println
import lib::*

fn main() -> i32 {
    println(f"{scaled(1)} {mask()} {floor8()} {wide(0)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// lib.k's generic and inline bodies are spelled here, from lib.k's table.
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 1001 18446744073709551615 -128 18446744073709551617
