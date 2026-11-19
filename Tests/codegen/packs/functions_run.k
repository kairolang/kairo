// A generic pack function by what it computes: one element per argument, an
// empty pack, `xs...` forwarded to another pack function, a keyword-only
// parameter after the pack by its default and by its name, and `for x in
// xs` once per element with `continue`, `break` and `return` keeping their
// meaning. No emitted text is pinned.

fn <T> one(const x: T) -> i32 { return 1 }

fn <...T> count(...args: T) -> i32 {
    var n = 0
    for arg in args {
        n += one(arg)
    }
    return n
}

fn <...T> third_times_ten(...args: T) -> i32 {
    var i = 0
    for a in args {
        i += 1
        if i == 2 { continue }
        if i == 3 { return i * 10 }
        if i == 9 { break }
    }
    return -1
}

fn <T, ...U> head(x: T, ...ys: U) -> T { return x }
fn <...T> scaled(...xs: T, scale: i32 = 2) -> i32 { return scale + count(xs...) }
fn <...T> doubled(...xs: T) -> i32 { return count(xs...) + count(xs...) }
fn <...T> none(...xs: T) -> i32 { return 5 }

fn main() -> i32 {
    if count(42, "hello", true) != 3 { return 1 }
    if count() != 0 { return 2 }
    if head(7, 1.0, "x") != 7 { return 3 }
    if scaled(1, 2, scale: 3) != 5 { return 4 }
    if scaled(1.5) != 3 { return 5 }
    if scaled() != 2 { return 6 }
    if doubled(1, 2, 2.0) != 6 { return 7 }
    if none() != 5 { return 8 }
    if third_times_ten(1, 2u8, 3.0, 4) != 30 { return 9 }
    if third_times_ten(1) != -1 { return 10 }
    if third_times_ten() != -1 { return 11 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
