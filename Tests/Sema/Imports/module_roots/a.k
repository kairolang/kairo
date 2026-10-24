// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// The cwd's `a`. Its twin in library `foo` is libfoo/a.k; the two
// are different modules and must stay different decls.
//
// CHECK-NOT: error

pub fn add() -> i32 { return 1 }
