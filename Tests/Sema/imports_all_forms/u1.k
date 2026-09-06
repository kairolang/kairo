// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// Support file for main.k: half of a module reopened across two files.
//
// CHECK-NOT: error

pub module util {
    pub fn one() -> i32 { return 1 }
}
