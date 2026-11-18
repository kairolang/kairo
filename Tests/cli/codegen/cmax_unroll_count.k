// --cmax-unroll-count=N is LLVM's unroll-count when N > 0; 0 means the backend default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --cmax-unroll-count=4 || true; } | %FileCheck %s --check-prefix=ON
// ON: -mllvm -unroll-count=4
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -unroll-count
