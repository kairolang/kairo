// A float keys no map or set: f32 and f64 do not implement Hash (NaN is
// not equal to itself, and -0.0 equals 0.0 with different bits).

fn main() -> i32 {
    var m: {f64: i32}
    var s: {f32}
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: float_key_rejected.k:5:12: error [SC162E]: 'f64' does not conform to 'Hash'
// CHECK-DAG: float_key_rejected.k:6:12: error [SC162E]: 'f32' does not conform to 'Hash'
