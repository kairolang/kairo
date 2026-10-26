// Nested closures: a binding an inner closure uses is captured by every
// closure between it and its declaration, each in its own mode. Under an
// outer `|*total|` the name is already the pointer, so an inner closure
// copies that pointer (by default, or `|*total|` again) and its writes
// reach the original; under an outer copy, an inner `|*c|` points at the
// outer closure's own copy, which persists between the outer's calls. An
// inner closure may read an outer closure's parameter.

import std::io::println

fn main() -> i32 {
    var total = 0
    var outer = fn ()|*total| {
        var inner = fn (d: i32) { *total += d }
        inner(5)
        var inner2 = fn ()|*total| { *total += 100 }
        inner2()
    }
    outer()
    outer()
    println(f"through pointer: {total}")

    var c = 0
    var outer_copy = fn () -> i32 {
        var bump = fn ()|*c| { *c += 1 }
        bump()
        bump()
        return c
    }
    outer_copy()
    println(f"outer copy: {outer_copy()} original: {c}")

    var adder = fn (a: i32) -> i32 {
        var add = fn (b: i32) -> i32 = a + b
        return add(1) + add(2)
    }
    println(f"outer param: {adder(10)}")
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
// OUT:      through pointer: 210
// OUT-NEXT: outer copy: 4 original: 0
// OUT-NEXT: outer param: 23

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: own(new auto([total = & total]() mutable->void {
// CXX: own(new auto([total](signed int d) mutable->void {
// CXX: own(new auto([total]() mutable->void {
// CXX: own(new auto([c]() mutable->signed int {
// CXX: own(new auto([c = & c]() mutable->void {
