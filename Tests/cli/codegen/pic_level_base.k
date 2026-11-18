// --pic-level=N sets the cc1 PIC level: 1 and 2 add `-mrelocation-model pic
// -pic-level N`, 0 adds nothing. Out-of-range values are rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --target=x86_64-linux-musl --print-clang-args --pic-level=2 %s | %FileCheck %s --check-prefix=L2
// L2: -mrelocation-model pic -pic-level 2
// RUN: %kairo --target=x86_64-linux-musl --print-clang-args --pic-level=1 %s | %FileCheck %s --check-prefix=L1
// L1: -mrelocation-model pic -pic-level 1
// RUN: %kairo --target=x86_64-linux-musl --print-clang-args --pic-level=0 %s | %FileCheck %s --check-prefix=L0
// L0-NOT: -pic-level
// RUN: { %kairo --pic-level=7 %s 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: out of range [0, 2]
