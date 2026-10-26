// Capture by pointer (closures.md, Capture by Pointer and Mixed Capture;
// ownership.md, Capture by pointer): inside the closure the name IS a
// `*T` to the original, read and written through `*x`, so every write
// is seen outside, and a write outside is seen by the next call. `|*|`
// takes every captured binding that way, `|*b|` only the one it names,
// beside `a` by copy. A struct reached through the pointer is written in
// place. An `@inout` parameter captured by pointer points at the
// caller's variable.

import std::io::println

struct Pair { pub var l: i32 = 0; pub var r: i32 = 0 }

fn bump_twice(@inout n: i32) {
    var inc = fn ()|*n| { *n += 1 }
    inc()
    inc()
}

fn main() -> i32 {
    var count = 0
    var increment = fn ()|*| {
        *count += 1
    }
    increment()
    increment()
    println(f"all: {count}")

    var a = 10
    var b = 20
    var closure = fn (x: i32)|a, *b| -> i32 {
        *b += 1
        return x + a + *b
    }
    println(f"mixed: {closure(5)} a: {a} b: {b}")

    var seen = fn ()|*b| -> i32 { return *b }
    b = 50
    println(f"sees later write: {seen()}")

    var p = Pair { l: 1, r: 2 }
    var swap = fn ()|*p| { var t = (*p).l; (*p).l = (*p).r; (*p).r = t }
    swap()
    println(f"struct: {p.l} {p.r}")

    var n = 3
    bump_twice(&n)
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
// OUT:      all: 2
// OUT-NEXT: mixed: 36 a: 10 b: 21
// OUT-NEXT: sees later write: 50
// OUT-NEXT: struct: 2 1
// OUT-NEXT: inout: 5

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: own(new auto([count = & count]() mutable->void {
// CXX: own(new auto([a, b = & b](signed int x) mutable->signed int {
