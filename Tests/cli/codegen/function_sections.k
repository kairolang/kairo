// -ffunction-sections is forwarded alone, without -fdata-sections.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ffunction-sections || true; } | %FileCheck %s --check-prefix=ON
// ON: -ffunction-sections
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ffunction-sections || true; } | %FileCheck %s --check-prefix=ONN
// ONN-NOT: -fdata-sections
