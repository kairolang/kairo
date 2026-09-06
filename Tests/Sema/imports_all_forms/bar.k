// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// Support file for main.k. Re-exported THROUGH foo (`pub import bar::*`),
// so `foo::f` must bind in a file that imports only foo.
//
// CHECK-NOT: error

pub fn f() -> i32 { return 1 }
