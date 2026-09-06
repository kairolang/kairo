// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// The ENTRY-root `a`. Its twin under the named root is libfoo/a.k; the two
// are different modules and must stay different decls.
//
// CHECK-NOT: error

pub fn add() -> i32 { return 1 }
