// A C++ variable that is not `constexpr` stays a run-time value to an eval
// context, `const int` and an in-class `static const` member included.
ffi "c++" import "consts.h"

eval A: i32 = K_CONST + 1
eval B: u32 = K_MUT
eval C: u32 = K_EXTERN
eval D: i32 = Limits2::MIN

fn main() { }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: reject.k:5:15: error [SC189E]: an eval context reads only compile-time values; 'K_CONST' is a global, static or thread variable that is not 'eval'
// CHECK-DAG: reject.k:6:15: error [SC189E]: an eval context reads only compile-time values; 'K_MUT' is a global, static or thread variable that is not 'eval'
// CHECK-DAG: reject.k:7:15: error [SC189E]: an eval context reads only compile-time values; 'K_EXTERN' is a global, static or thread variable that is not 'eval'
// CHECK-DAG: reject.k:8:15: error [SC189E]: an eval context reads only compile-time values; 'MIN' is a global, static or thread variable that is not 'eval'
