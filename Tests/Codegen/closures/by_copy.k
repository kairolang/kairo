// Capture by copy, the default (closures.md, Capture Modes; ownership.md,
// Default capture): the closure gets its own copy when it is MADE, so a
// later change to the original is not seen and a change to the copy does
// not reach the original. The copy is the closure's own variable: it
// persists from one call to the next. Copying the closure copies its
// captures too, so the two copies count on separately. A named list
// (`|a, b|`) copies exactly what it names, and a parameter of the
// enclosing function is captured like a local.

import std::io::println

fn counter_from(start: i32) -> i32 {
    var next = fn () -> i32 { start += 1; return start }
    next()
    next()
    return next() * 100 + start
}

fn main() -> i32 {
    var x = 10
    var add_x = fn (y: i32) -> i32 {
        return y + x
    }
    x = 999
    println(f"made before: {add_x(5)}")

    var acc = 0
    var keep = fn () -> i32 { acc += 1; return acc }
    keep()
    keep()
    println(f"persists: {keep()} original: {acc}")

    var copy = keep
    copy()
    println(f"copy: {copy()} source: {keep()}")

    var a = 1
    var b = 2
    var named = fn ()|a, b| -> i32 { a += 10; return a + b }
    named()
    println(f"named: {named()} a: {a} b: {b}")

    println(f"param: {counter_from(5)}")
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
// OUT:      made before: 15
// OUT-NEXT: persists: 3 original: 0
// OUT-NEXT: copy: 5 source: 4
// OUT-NEXT: named: 23 a: 1 b: 2
// OUT-NEXT: param: 805

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: own(new auto([x](signed int y) mutable->signed int {
// CXX: own(new auto([a, b]() mutable->signed int {
