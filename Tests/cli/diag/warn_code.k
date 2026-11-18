// -W <code> re-enables a code. Applied after -A, so `-A SC005 -W SC005` leaves
// the warning visible; the order on the command line does not matter. Before,
// -W only ever reached clang and never touched a native diagnostic.

fn f(__x: i32) -> i32 { return __x }
fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -A SC005 -W SC005 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only -W SC005 -A SC005 2>&1 || true; } | %FileCheck %s
// CHECK: warning [SC005W]: parameter name is reserved
