// An `eval` constant is its value, so one without an initializer -- a
// binding or a class's eval field -- is an error rather than a zero C++
// would make up (EVAL.md 1.2).
eval N: i32
class C { pub eval K: i32 }
fn main() -> i32 { return C::K + N }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_needs_init.k:4:6: error [SC001E]: 'N' is an 'eval' constant and needs an initializer: its value is computed at compile time
// CHECK: eval_needs_init.k:5:20: error [SC001E]: 'K' is an 'eval' constant and needs an initializer: its value is computed at compile time
