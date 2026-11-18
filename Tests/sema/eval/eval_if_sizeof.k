eval if sizeof usize < 8 {
    fn narrow() -> i32 { return 1 }
} else {
    fn wide() -> i32 { return 0 }
}

eval PTR_BYTES = sizeof usize
eval if PTR_BYTES >= 8 {
    eval WIDE = true
}

class <T> Box { pub var v: T }

fn pick() -> i32 {
    eval if sizeof usize < 8 { return 32 }
    return 64
}

fn main() -> i32 {
    var small = sizeof usize < 8              // `usize`, then a comparison
    var boxed = sizeof Box<i32> == 4          // still generic arguments
    if small || (!boxed) { return 1 }
    if !WIDE { return 2 }
    return wide() + pick() - 64
}

// EVAL.md 4.2b. A declaration-scope `eval if` whose condition reads a type
// fact -- here `sizeof`, directly and through an `eval` constant -- waits
// for the late fold, which decides it once types are resolved: on a 64-bit
// target `narrow` is discarded, and `wide` and `WIDE` exist. In a function
// body the same condition is `if constexpr`. And `sizeof usize < 8` parses
// as `(sizeof usize) < 8`: a builtin primitive takes no generic arguments,
// so its `<` compares.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
