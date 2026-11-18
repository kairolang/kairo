// --cmax-threads is a hard cap on the thread pool whatever --threads asks
// for; the timing report prints the pool size.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --threads=8 --cmax-threads=2 --time-passes 2>&1 | %FileCheck %s
// CHECK: pool 2
