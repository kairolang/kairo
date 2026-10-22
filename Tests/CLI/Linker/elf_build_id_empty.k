// An empty --build-id= means the default (fast), not "no note": the flag must
// still reach lld as --build-id=fast.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --build-id= | %FileCheck %s --check-prefix=EMPTY
// EMPTY: --build-id=fast
