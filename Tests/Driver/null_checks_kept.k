// The optimizer keeps null checks and null dereferences unless
// -fdelete-null-pointer-checks is given: a safe pointer that holds null (from
// C++, from an unsafe cast) traps at its dereference at every level.
fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: %kairo %s --print-clang-args -O2 --type-check-only 2>&1 | %FileCheck %s --check-prefix=KEPT
// RUN: %kairo %s --print-clang-args -O2 --type-check-only -fdelete-null-pointer-checks 2>&1 | %FileCheck %s --check-prefix=GONE
// KEPT: -fno-delete-null-pointer-checks
// GONE-NOT: -fno-delete-null-pointer-checks
