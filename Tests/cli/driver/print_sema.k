// --print-sema dumps the resolved Sema state before the normal output; pins
// the header and that the unit reached the Checked phase.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-sema | %FileCheck %s
// CHECK: -- sema:
// CHECK: phase: Checked
