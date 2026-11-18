// --diag-show-ids is accepted for compatibility: codes always print, and its
// help says so instead of promising something it does not do.
fn main() -> i32 { var a: i32 = u1; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --diag-show-ids 2>&1 || true; } | %FileCheck %s
// RUN: %kairo --help | %FileCheck %s --check-prefix=HELP
// CHECK: error [R020E]: use of undeclared identifier 'u1'
// HELP: --diag-show-ids{{.*}}print diagnostic codes (always on; accepted for compatibility)
