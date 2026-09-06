// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// Support file for main.k. Imported by foo PRIVATELY, so `foo::h` must NOT
// bind in a file that imports only foo (wall 1).
//
// CHECK-NOT: error

pub fn h() -> i32 { return 2 }
