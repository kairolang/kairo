// An array length must be a compile-time constant: a C++ variable that is
// not `constexpr` is a run-time value there.
ffi "c++" import "consts.h"

fn main() {
    var a: [u8; K_MUT]
    var b: [u8; K_CONST]
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: reject_extent.k:6:17: error [SC192E]: an array length must be an 'eval' constant; 'K_MUT' is a variable
// CHECK-DAG: reject_extent.k:7:17: error [SC192E]: an array length must be a compile-time constant: 'K_CONST' has no initializer that evaluates
