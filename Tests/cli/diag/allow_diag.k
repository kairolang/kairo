// -A <code> silences a warning by code, in both the spaced and attached
// spellings. Without it the warning is reported.

fn f(__x: i32) -> i32 { return __x }
fn main() -> i32 { return f(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WARN
// RUN: { %kairo %s --type-check-only -A SC005 2>&1 || true; } | %FileCheck %s --check-prefix=ALLOW --allow-empty
// RUN: { %kairo %s --type-check-only -ASC005W 2>&1 || true; } | %FileCheck %s --check-prefix=ALLOW --allow-empty
// WARN: warning [SC005W]: parameter name is reserved
// ALLOW-NOT: SC005
