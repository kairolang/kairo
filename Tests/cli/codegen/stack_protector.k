// -fstack-protector is cc1's -stack-protector 1 (strong off, plain protector on).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fstack-protector || true; } | %FileCheck %s --check-prefix=ON
// ON: -stack-protector 1
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -stack-protector
