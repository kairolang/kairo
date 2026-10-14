// --no-implicit-float is -no-implicit-float.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --no-implicit-float || true; } | %FileCheck %s --check-prefix=ON
// ON: -no-implicit-float
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -no-implicit-float
