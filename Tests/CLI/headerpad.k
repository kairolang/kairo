// --headerpad is range-checked at flag parse time (0..65536); that check is
// the only live behaviour of the flag. It is a driver-level error, so it has
// no source location.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only --headerpad=70000 %s 2>&1 || true; } | %FileCheck %s
// CHECK: error [U003E]: flag {{.*}} value 70000 is out of range [0, 65536]
