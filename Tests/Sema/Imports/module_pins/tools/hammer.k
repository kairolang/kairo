// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `acme::tools::hammer`.
//
// CHECK-NOT: error

pub fn swing() -> i32 { return 3 }
