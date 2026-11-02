// `@no_warn(CODE)` drops those warnings inside the declaration it is on,
// whichever pass reports them; the same code outside it still warns.

@no_warn(SC031W)
fn quiet() -> i32 { var y: i32 = 1 as i32; return y }

fn loud() -> i32 { var y: i32 = 1 as i32; return y }

@no_warn(SC001W)
fn uses_old() -> i32 { return old() }

@deprecated fn old() -> i32 { return 0 }

fn uses_old_loud() -> i32 { return old() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: attr_no_warn.k:7:{{[0-9]+}}: warning [SC031W]: redundant cast
// CHECK-DAG: attr_no_warn.k:14:{{[0-9]+}}: warning [SC001W]: 'old' is deprecated
