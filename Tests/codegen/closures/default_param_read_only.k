// The literal's defaults still apply to a local that is only read: called,
// copied into another variable, captured by copy or by const pointer, and
// passed by value. A `const` binding and a `static` local keep them too.

fn twice(g: fn(i32, i32) -> i32) -> i32 {
    return g(1, 1) * 2
}

fn main() -> i32 {
    var   f        = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    const c        = fn (a: i32, b: i32 = 7) -> i32 { return a * b }
    var   copy     = f
    var   by_copy  = fn () -> i32 { return f(2, 2) }
    var   by_const = fn ()|const *f| -> i32 { return 3 }
    var   r        = f(1)                                            // 6
    r += c(2)       // 14
    r += twice(f)   // 4
    r += copy(1, 1) // 2
    r += by_copy()  // 4
    r += by_const() // 3
    static s = fn (a: i32, b: i32 = 2) -> i32 { return a - b }
    r += s(9) // 7
    return r  // 40
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 40
