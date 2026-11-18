fn root(x: f128) -> f128 {
    return x.sqrt()
}

fn main() -> i32 {
    var y = 2.0f128.fma(3.0, 1.0)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A file that names f128 (the keyword, or a literal's suffix) imports
// num/f128_ext.k implicitly, and with it the engine its sqrt and fma call.
// RUN: { %kairo %s --type-check-only --print-imports 2>&1 || true; } | %FileCheck %s
// The implicit import is printed with no path: the one edge of the file.
// CHECK: fid 0: 1 edge(s)
// CHECK-NEXT: [wildcard] -> fid
// CHECK: num::softfloat
// CHECK-NOT: error [
// RUN: %kairo %s --type-check-only
