// A const function is spelled after its parameters, where the other
// specifiers go: `fn foo() const -> T`. A leading `const fn` is an error
// with a fix-it removing it (it reads as a binding, `const x = 1`); the
// declaration still parses as const, so nothing after it cascades.

fn good() const -> (i32, f32) {
    return (1, 2.0)
}

const fn bad() -> (i32, f32) {
    return (1, 2.0)
}

fn main() -> i32 {
    var (a, b) = good()
    var (c, d) = bad()
    return a + c - 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: const_fn_spelling.k:6:
// CHECK: const_fn_spelling.k:10:1: error [S047E]: a const function is spelled 'fn name(...) const', after the parameters, not with a leading 'const'
// CHECK: fix-it:{{.*}}{10:1-10:6}:""
// CHECK-NOT: error
