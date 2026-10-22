// --threads=N sets the linker's thread count (--threads=N on the ld line),
// and a value above the registry maximum is rejected by the driver.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: %kairo %s --threads=4 --print-ld-args | %FileCheck %s
// CHECK: --threads=4
// RUN: { %kairo %s --threads=2000 2>&1 || true; } | %FileCheck %s --check-prefix=RANGE
// RANGE: out of range [0, 1024]
