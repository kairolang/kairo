// -funroll-loops and -fno-unroll-loops are forwarded; the default line has neither.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -funroll-loops || true; } | %FileCheck %s --check-prefix=ON
// ON: -funroll-loops
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-unroll-loops || true; } | %FileCheck %s --check-prefix=OFF
// OFF: -fno-unroll-loops
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: unroll-loops
