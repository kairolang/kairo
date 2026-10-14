// --no-builtins drops the builtin prelude from name resolution, so a name the
// builtins declare (Ordering) becomes undeclared. Guards against the flag
// silently becoming a no-op.

fn f() -> i32 { var o = Ordering::Less; return 0 }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only --no-builtins %s 2>&1 || true; } | %FileCheck %s
// CHECK: error [R020E]: {{.*}}'Ordering'
