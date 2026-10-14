// --cinline-cost-threshold is LLVM's inline-threshold, as an integer, and only
// when given: the default differs per optimization level inside LLVM.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --cinline-cost-threshold=100 || true; } | %FileCheck %s --check-prefix=ON
// ON: -mllvm -inline-threshold=100
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -inline-threshold
