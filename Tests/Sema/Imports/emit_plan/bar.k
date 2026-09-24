// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// CHECK-NOT: error
// The TU main.k never imports. It lands in the plan anyway, because foo's F
// holds a B by value and invariant 11 says a class enters the interface
// whole. That is what IMPORTS.md §6.2 means by "bar depends on something foo
// brought in", and it is handled by the closure, not by import order.

pub class B { var n: i32; }

pub class Deep { var b: B; }
