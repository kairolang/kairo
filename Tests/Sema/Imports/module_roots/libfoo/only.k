// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `foo::only`: a file that exists only in the pinned library, so
// ../pinned_by_name.k can tell "reached by its name" from "reached at all".
//
// CHECK-NOT: error

pub fn only() -> i32 { return 3 }
