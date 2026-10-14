// --syntax-only stops after parsing, so a type error in the file is not
// reported; --type-check-only on the same file does report it. Pins that
// the two flags stop at different stages.

fn main() -> i32 { var x: i32 = "s"; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --syntax-only
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: [SC028E]
