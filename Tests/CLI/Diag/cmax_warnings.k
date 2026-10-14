// --cmax-warnings=N delivers N warnings, then one "too many warnings" line,
// and drops the rest. 0 (the default) is unlimited.

fn f(__x: i32) -> i32 { return __x }
fn g(__y: i32) -> i32 { return __y }
fn main() -> i32 { return f(0) + g(0) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-warnings=1 2>&1 || true; } | %FileCheck %s --check-prefix=CAP
// RUN: { %kairo %s --type-check-only --cmax-warnings=0 2>&1 || true; } | %FileCheck %s --check-prefix=ALL
// CAP: warning [SC005W]: parameter name is reserved
// CAP-NEXT: warning [U001W]: too many warnings emitted, further warnings will be suppressed
// CAP-NOT: SC005W
// ALL: warning [SC005W]: parameter name is reserved
// ALL: warning [SC005W]: parameter name is reserved
// ALL-NOT: too many warnings
