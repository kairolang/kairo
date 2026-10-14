// -fno-inline reaches cc1 as -fno-inline; the default line has none.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-inline || true; } | %FileCheck %s --check-prefix=OFF
// OFF: -fno-inline
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -fno-inline
