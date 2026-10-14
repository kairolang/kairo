// --print-symbols dumps the resolved scopes per file id before anything else.
// The user file's own block must name its top-level function.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-symbols | %FileCheck %s
// CHECK: SYMBOLS for fid
// CHECK: scope <tu>
// CHECK: main
