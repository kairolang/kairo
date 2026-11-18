// A closure returned as `fn(...) -> R` (closures.md, Tether and Lifetime
// Safety, the capture-by-copy form; Nested Closures): the copy it captured
// lives in the closure, not in the frame that made it, so it is still
// there after that frame returns, and each closure a factory returns has
// its own. A closure returned from a closure, written in the expression
// and block forms, and called through the result of a call.

import std::io::println

fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }
}

fn make_adder(base: i32) -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x + base }
}

fn make_counter() -> fn() -> i32 {
    var n = 0
    return fn () -> i32 { n += 1; return n }
}

fn main() -> i32 {
    var f = make_closure()
    println(f"copied: {f()}")

    var add5 = make_adder(5)
    var add7 = make_adder(7)
    println(f"adders: {add5(1)} {add7(1)}")

    var c1 = make_counter()
    var c2 = make_counter()
    c1()
    c1()
    println(f"counters: {c1()} {c2()}")

    var nested = fn () = fn (x: i32) -> i32 = x * 2
    var nested_block = fn () -> fn(i32) -> i32 {
        return fn (x: i32) -> i32 { return x + 1 }
    }
    var nested_mixed = fn () -> fn(i32) -> i32 {
        var offset = 10
        return fn (x: i32) -> i32 = x + offset
    }
    println(f"nested: {nested()(4)} {nested_block()(4)} {nested_mixed()(4)}")
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
// OUT:      copied: 42
// OUT-NEXT: adders: 6 8
// OUT-NEXT: counters: 3 1
// OUT-NEXT: nested: 8 5 14
