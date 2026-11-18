// OperatorSemantics: a shift count that evaluates at compile time must be
// in [0, W) (SC001E). At run time a count is taken modulo the register
// width; a constant that large is a mistake, not a request for the modulo.

eval K: i32 = 40

fn counts(x: u8, y: i32, n: i32) -> i32 {
    var a = x << 8
    var b = y >> 32
    var c = y << -1
    var d = y << K
    var z = y
    z <<= 33
    var k: i32 = 1i32 << 33
    var ok1 = x << 7
    var ok2 = y >> 31
    var ok3 = y << n
    var wide: i64 = 1 << 40
    return (a as i32) + b + c + d + z + k + (ok1 as i32) + ok2 + ok3 + (wide as i32)
}

fn main() -> i32 { return counts(1, 2, 3) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: shift_count_error.k:8:18: error [SC262E]: shift count 8 is not below the width of 'u8' (8 bits)
// CHECK: shift_count_error.k:9:18: error [SC262E]: shift count 32 is not below the width of 'i32' (32 bits)
// CHECK: shift_count_error.k:10:18: error [SC262E]: shift count -1 is negative; a constant count of a 'i32' shift must be in 0..32
// CHECK: shift_count_error.k:11:18: error [SC262E]: shift count 40 is not below the width of 'i32' (32 bits)
// CHECK: shift_count_error.k:5:1: note [{{[A-Z0-9]+}}]: 'K' is declared here
// CHECK: shift_count_error.k:13:11: error [SC262E]: shift count 33 is not below the width of 'i32' (32 bits)
// CHECK: shift_count_error.k:14:26: error [SC262E]: shift count 33 is not below the width of 'i32' (32 bits)
// CHECK-NOT: error
