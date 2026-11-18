// A closure stored and called later (closures.md, Basic Syntax; Function
// Pointers in functions.md): in an annotated `fn` local, in a struct
// field, in a global, reassigned from a named function to a closure and
// back, a nullable `fn` checked before the call, and an `@inout`
// parameter in the function type.

import std::io::println

struct Handler { pub var on: fn(i32) -> i32 }

var global_twice = fn (v: i32) -> i32 { return v * 2 }

fn neg(v: i32) -> i32 { return 0 - v }
fn bump(@inout n: i32) { n += 1 }

fn main() -> i32 {
    var opr: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }
    println(f"annotated: {opr(3, 4)}")

    var base = 100
    var h = Handler { on: fn (v: i32) -> i32 { return v + base } }
    println(f"field: {h.on(1)}")

    println(f"global: {global_twice(5)}")

    var f: fn(i32) -> i32 = neg
    println(f"named: {f(5)}")
    f = fn (v: i32) -> i32 { return v - base }
    println(f"closure: {f(5)}")
    f = global_twice
    println(f"global value: {f(5)}")

    var maybe: (fn(i32) -> i32)? = null
    if maybe? { println("unexpected") } else { println("null fn") }
    maybe = fn (v: i32) -> i32 { return v + base + 1 }
    if maybe? { println(f"nullable: {maybe(0)}") }

    var g: fn(@inout i32) = bump
    var n = 1
    g(&n)
    println(f"inout: {n}")
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
// OUT:      annotated: 7
// OUT-NEXT: field: 101
// OUT-NEXT: global: 10
// OUT-NEXT: named: -5
// OUT-NEXT: closure: -95
// OUT-NEXT: global value: 10
// OUT-NEXT: null fn
// OUT-NEXT: nullable: 101
// OUT-NEXT: inout: 2
