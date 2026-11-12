// A file-scope `finally` has no enclosing function: no body for its guard
// to be local to and no scope that is ever left. It is an error, not an
// internal error in MoveCheck or FinallyLowering, bare or inside a file-scope block;
// one in a function body beside it is fine.

finally { }

{ finally { var x = 1 } }

fn ok() { finally { } }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: finally_file_scope.k:6:1: error [SC239E]: `finally` outside of a function body
// CHECK: finally_file_scope.k:8:3: error [SC239E]: `finally` outside of a function body
// CHECK-NOT: {{error|Internal}}
