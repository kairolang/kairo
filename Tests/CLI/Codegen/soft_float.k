// -fsoft-float is -msoft-float plus -mfloat-abi soft, after the probe's own float ABI.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fsoft-float || true; } | %FileCheck %s --check-prefix=ON
// ON: -msoft-float -mfloat-abi soft
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -msoft-float
