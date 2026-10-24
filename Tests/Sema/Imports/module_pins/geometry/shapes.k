// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `geo::shapes`: a file at the pinned library's top level.
//
// CHECK-NOT: error

pub fn area() -> i32 { return 4 }
