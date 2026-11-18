// A constant index into a fixed array that is negative or past its extent
// is an error at the index (SC291E): the extent and the index are
// both known, and the access can only fail. Without it --type-check-only
// passes silently, and a build gets clang's C047W at best. An index that is not a
// constant, a slice, and an array of a generic extent are not checked.

const LAST: usize = 1

fn f(i: usize) -> i32 {
    var a: [i32; 2] = [1, 2]
    a[5] = 1
    var b = a[LAST + 1]
    var c = a[LAST]
    var d = a[i]
    var g: [[u8; 3]; 2] = [[1, 2, 3], [4, 5, 6]]
    var h = g[1][3]
    return a[7] + b + c + d + (h as i32)
}

fn <eval N: usize> e(const xs: [i32; N]) -> i32 = xs[5]

fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: array_index_constant_oob.k:11:7: error [SC291E]: index 5 is out of range for '[i32; 2]', which has 2 elements
// CHECK: array_index_constant_oob.k:12:15: error [SC291E]: index 2 is out of range for '[i32; 2]', which has 2 elements
// CHECK: array_index_constant_oob.k:16:18: error [SC291E]: index 3 is out of range for '[u8; 3]', which has 3 elements
// CHECK: array_index_constant_oob.k:17:14: error [SC291E]: index 7 is out of range for '[i32; 2]', which has 2 elements
