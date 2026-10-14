// --prelude <file> REPLACES the default builtin prelude with a file imported
// as `<file>::*`, so its public declarations are visible to the main file.

fn main() -> i32 { return helper() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --prelude=%S/Inputs/helper_prelude.k 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: helper
