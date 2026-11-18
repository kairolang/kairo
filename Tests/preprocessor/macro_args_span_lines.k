// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
//
// A macro invocation's `( ... )` is a bracket: a newline in it terminates
// nothing, as in a call. The argument tokens must not keep their newlines:
// `check!(x` newline `> 3, ...)` would expand to a condition that ends at
// the line break (S052E / S057E, then a cascade into the next function).
// A newline inside an argument's own `{ }` still separates statements.

macro check!(cond, v) { if (cond) { return v } }
macro run!(body) { body }

fn split(x: i32) -> i32 {
    check!(
        x
            > 3,
        10
    )
    return 0
}

fn block() -> i32 {
    var n = 0
    run!({
        n += 1
        n += 1
    })
    return n
}

fn main() -> i32 {
    return split(5) + block()
}

// DIAG-NOT: error
