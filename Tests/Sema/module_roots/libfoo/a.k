// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// The `foo::a` under the named root. Same file name as ../a.k on purpose.
//
// CHECK-NOT: error

pub fn add() -> i32 { return 2 }
