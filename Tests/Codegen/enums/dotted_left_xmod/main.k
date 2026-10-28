// `.V` as the LEFT operand of `==` / `!=` against a value whose enum lives
// in another module (lib.k): the right operand is typed first and its enum,
// an imported one, is where `.V` is looked up. A generic imported ADT
// compares tags (`.Nothing == m`) as it does with the operands swapped.

import std::io::println
import lib::*

fn main() -> i32 {
    var c = favourite()
    var m = wrap(5)
    var r = 0
    if .Green == c { r += 1 }
    if .Red != c { r += 2 }
    if .Blue == favourite() { r += 100 }
    if .Nothing != m { r += 4 }
    var j = (.Just { v: 9 }) == m
    if j { r += 8 }
    println(f"{r}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 15
