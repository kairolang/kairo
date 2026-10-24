// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// The cwd's `a`. Its twin is Inputs/a.k, also `a` under `-I Inputs`; run on
// its own (no -I, no import) it is unremarkable.
//
// CHECK-NOT: error

pub fn which() -> i32 { return 1 }
