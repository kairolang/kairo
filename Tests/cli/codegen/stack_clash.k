// --stack-clash is -fstack-clash-protection.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --stack-clash || true; } | %FileCheck %s --check-prefix=ON
// ON: -fstack-clash-protection
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -fstack-clash-protection
