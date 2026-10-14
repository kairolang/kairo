// --print-ast=<mode> dumps the tree in one of tree, flat or canonical; any
// other value is a fatal driver error listing the accepted modes.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-ast=flat 2>&1 || true; } | %FileCheck %s
// CHECK: AST (flat) for fid 0
// CHECK: fn main() -> i32 { return 0 }
// RUN: { %kairo %s --type-check-only --print-ast=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: fatal [I010F]: invalid --print-ast value 'bogus'; expected one of: tree, flat, canonical
