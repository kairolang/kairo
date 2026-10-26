// A closure that captures nothing (closures.md, Basic Syntax; Empty Capture
// List): a block body and an expression body, an inferred return type, the
// explicit empty list `||`, called directly, stored and called later, and
// called on the spot. It is a plain function inside its `fn` value: the
// lambda is converted with unary `+`, and no heap object is made.

import std::io::println

fn main() -> i32 {
    var add = fn (a: i32, b: i32) -> i32 {
        return a + b
    }
    var twice = fn (x: i32) -> i32 = x * 2
    var inferred = fn (x: i32) = x + 1
    var no_capture = fn ()|| -> i32 {
        return 42
    }
    var spaced = fn ()| | -> i32 = 7
    var say = fn (s: string) { println(s) }

    println(f"add: {add(3, 4)}")
    println(f"twice: {twice(10)}")
    println(f"inferred: {inferred(1)}")
    println(f"none: {no_capture()}")
    println(f"spaced: {spaced()}")
    say("say: hi")
    println(f"on the spot: {(fn (x: i32) -> i32 = x - 1)(5)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      add: 7
// OUT-NEXT: twice: 20
// OUT-NEXT: inferred: 2
// OUT-NEXT: none: 42
// OUT-NEXT: spaced: 7
// OUT-NEXT: say: hi
// OUT-NEXT: on the spot: 4

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ::__kairo_fn<signed int(signed int, signed int)> add = ::__kairo_fn<signed int(signed int, signed int)>(+[](signed int a, signed int b)->signed int {
// CXX-NOT: own(
