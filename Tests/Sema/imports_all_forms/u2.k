// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// Support file for main.k: the other half of `module util`. Two files
// reopening one module are ONE namespace, not an ambiguous import.
//
// CHECK-NOT: error

pub module util {
    pub fn two() -> i32 { return 2 }
}
