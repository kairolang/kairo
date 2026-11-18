// --mabi becomes -target-abi after the probe's per-target one, so it wins as the
// last. cc1 itself rejects an ABI the target does not have.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=riscv64-linux-gnu --mabi=lp64f || true; } | %FileCheck %s --check-prefix=ABI
// ABI: -target-abi lp64d
// ABI: -target-abi lp64f
