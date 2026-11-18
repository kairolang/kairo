// The unknown-flag suggestion never offers the spelling it just rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --include 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: did you mean '--include'
// RUN: { %kairo %s --type-check-only --type-chek-only 2>&1 || true; } | %FileCheck %s --check-prefix=NEAR
// NEAR: unknown flag '--type-chek-only'; did you mean '--type-check-only'
