// `unsafe { e }` in an expression holds one expression and would read as a
// one-element set: S073E rewrites the braces to `unsafe (e)`. A set with two
// elements or a trailing comma stays a set, and a statement block is untouched.

fn main() -> i32 {
    var a = unsafe { 1 + 2 }
    var s = unsafe { 1, 2 }
    var t = unsafe { 3, }
    unsafe { a = 5 }
    return a - 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: unsafe_braces_expression.k:6:20: error [S073E]: 'unsafe { e }' in an expression is a set literal; the expression form is 'unsafe (e)'
// CHECK-NEXT: fix-it:"{{.*}}":{6:20-6:21}:"("
// CHECK-NEXT: fix-it:"{{.*}}":{6:28-6:29}:")"
