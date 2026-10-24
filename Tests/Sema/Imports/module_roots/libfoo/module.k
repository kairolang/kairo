// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// Pins libfoo/ as library `foo`: ../main.k imports `foo::a` by this name,
// not by the folder's.
//
// CHECK-NOT: error

module foo
