fn main() -> i32 {
    var x: f64 = 2.0
    return x.sqrt() as i32
}

// --- lit wiring -----------------------------------------------------------
// The native floats' methods (num/float_ext.k) are in every program; f128's
// (num/f128_ext.k, whose sqrt and fma run the softfloat engine) only in the
// files that name `f128`. f128_methods_user.k is the other half.
// RUN: { %kairo %s --type-check-only --print-imports 2>&1 || true; } | %FileCheck %s
// CHECK: -- imports:
// CHECK-NEXT: fid 0: 0 edge(s)
// CHECK: num::float_ext
// CHECK-NOT: softfloat
// CHECK-NOT: error [
