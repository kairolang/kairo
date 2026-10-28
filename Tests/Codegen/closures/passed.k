// A closure passed where a `fn` is expected (closures.md, Passing
// Closures to Functions): a parameter of a Kairo function, written in the
// call or passed from a local; the higher-order `map` pattern; a generic
// function's `fn(T) -> T` parameter; a closure made inside a generic body
// (its captures typed by the instance); and a C function's `int (*)(int)`
// parameter, which takes a named function, a closure that captures
// nothing, or a `fn` local holding either (the value converts back to the
// function pointer).

ffi "c" import "c_callback.h"
import std::io::println

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

fn map3(const data: [i32; 3], transform: fn(i32) -> i32) -> i32 {
    var total = 0
    for item in data { total = total * 100 + transform(item) }
    return total
}

fn <T> apply_g(f: fn(T) -> T, x: T) -> T { return f(x) }

// `: type`: an unbounded T has no `+` (MONO.md D0); C++ checks this one.
fn <T: type> add_to(x: T, y: T) -> T {
    var g = fn (z: T) -> T { return z + x }
    return g(y)
}

fn twice(x: i32) -> i32 { return x * 2 }

fn main() -> i32 {
    println(f"literal: {apply(fn (x: i32) -> i32 { return x * 2 }, 21)}")
    var k = 3
    var triple = fn (x: i32) -> i32 { return x * k }
    println(f"local: {apply(triple, 10)}")
    var data: [i32; 3] = [1, 2, 3]
    println(f"map: {map3(data, fn (x: i32) -> i32 { return x * 2 })}")
    println(f"generic: {apply_g(triple, 4)} {apply_g(fn (s: f64) -> f64 = s / 2.0, 3.0)}")
    println(f"generic body: {add_to(40, 2)}")
    var plain: fn(i32) -> i32 = twice
    println(f"c: {c_apply(twice, 4)} {c_apply(fn (v: i32) -> i32 { return v + 1 }, 4)} {c_apply(plain, 10)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      literal: 42
// OUT-NEXT: local: 30
// OUT-NEXT: map: 20406
// OUT-NEXT: generic: 12 1.5
// OUT-NEXT: generic body: 42
// OUT-NEXT: c: 8 5 20
