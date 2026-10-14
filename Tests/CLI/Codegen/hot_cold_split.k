// --hot-cold-split is LLVM's hot-cold-split option, forwarded as an -mllvm word.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --hot-cold-split || true; } | %FileCheck %s --check-prefix=ON
// ON: -mllvm -hot-cold-split=true
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -hot-cold-split
