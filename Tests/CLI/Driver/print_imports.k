// --print-imports dumps the import graph. A file with no imports has no edges;
// only fid 0 is pinned since the other fids depend on builtin load order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-imports | %FileCheck %s
// CHECK: -- imports:
// CHECK: fid 0: 0 edge(s)
