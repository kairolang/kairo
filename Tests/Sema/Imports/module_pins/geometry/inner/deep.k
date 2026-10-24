// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `geo::inner::deep`: directories below a pinned library keep their names.
//
// CHECK-NOT: error

pub fn depth() -> i32 { return 2 }
