// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// The other of two libraries pinning the same name; see ../main.k.
//
// CHECK-NOT: error

module dup
