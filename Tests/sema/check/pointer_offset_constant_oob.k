// A constant offset that takes a safe pointer into a fixed array before its
// first element or past one past its end is an error at the arithmetic
// (SC363E). The pointer is `&a[c]` in place, or a local initialized with it
// and never assigned, stepped or taken the address of afterwards. One past
// the end, a runtime offset, a reassigned local and an `unsafe *` pointer
// are not reported.

fn f(n: isize) -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    var *pa = &a[0]
    var *q = pa + 5
    var *r = pa - 1
    var *s = &a[2] + 2
    var *end = pa + 3
    var *back = &a[2] - 2
    var *rt = pa + n
    var *moved = &a[0]
    moved = &a[1]
    var *u = moved + 7
    unsafe {
        var raw: unsafe *i32 = &a[0] as unsafe *i32
        var unsafe *w = raw + 9
    }

    return *q + *r + *s + *end + *back + *rt + *u
}

fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: pointer_offset_constant_oob.k:11:14: error [SC363E]: offset 5 is outside '[i32; 3]', which allows 0 to 3
// CHECK-DAG: pointer_offset_constant_oob.k:12:14: error [SC363E]: offset -1 is outside '[i32; 3]', which allows 0 to 3
// CHECK-DAG: pointer_offset_constant_oob.k:13:14: error [SC363E]: offset 4 is outside '[i32; 3]', which allows 0 to 3
