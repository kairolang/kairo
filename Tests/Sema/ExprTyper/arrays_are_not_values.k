// `[T; N]` is a C array. It is a local, a field, a literal, a `const` or
// `@inout` parameter, and the thing a slice views. It is not copied, assigned,
// passed by value or returned.

fn by_value(xs: [i32; 3]) { }
fn by_const(const xs: [i32; 3]) { }
fn by_inout(@inout xs: [i32; 3]) { }

fn returns_one() -> [i32; 3] {
    return [1, 2, 3]
}

fn copies() {
    var a = [1, 2, 3];
    var b = a;
}

fn assigns() {
    var a = [1, 2, 3];
    var b = [4, 5, 6];
    a = b;
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: parameter 'xs' takes an array by value
// DIAG-NOT: parameter 'xs' takes an array by value
// DIAG: 'returns_one' returns an array
// DIAG: an array is not copyable
// DIAG: an array is not assignable
