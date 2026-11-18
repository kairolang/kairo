// --print-pass-pipeline has no implementation; it must no longer be treated
// as an info query that silently skips the compile. The compile runs.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-pass-pipeline --print-tokens | %FileCheck %s
// CHECK: token stream
