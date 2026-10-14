// -fpic selects the PIC relocation model at level 2; -fno-pic selects static.
// --pic-level is the explicit spelling and wins when both are given.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fpic || true; } | %FileCheck %s --check-prefix=PIC
// PIC: -mrelocation-model pic -pic-level 2
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-pic || true; } | %FileCheck %s --check-prefix=STATIC
// STATIC: -mrelocation-model static
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-pic --pic-level=1 || true; } | %FileCheck %s --check-prefix=LEVEL
// LEVEL: -mrelocation-model pic -pic-level 1
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-pic --pic-level=1 || true; } | %FileCheck %s --check-prefix=LEVELN
// LEVELN-NOT: -mrelocation-model static
