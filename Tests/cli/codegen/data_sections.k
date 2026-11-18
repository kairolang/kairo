// -fdata-sections is forwarded alone, without -ffunction-sections.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fdata-sections || true; } | %FileCheck %s --check-prefix=ON
// ON: -fdata-sections
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fdata-sections || true; } | %FileCheck %s --check-prefix=ONN
// ONN-NOT: -ffunction-sections
