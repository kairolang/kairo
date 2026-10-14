// --print-lowered dumps the lowering result, and it still runs when combined
// with --type-check-only, so lowering can be inspected without codegen.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-lowered | %FileCheck %s
// CHECK: -- lowered:
// CHECK: phase: Complete
