// Kairo's contraction default follows the target, not the host
// (ClangBackend::_decide_contract): -ffp-contract=on where the target's CPU
// and features give it a fused multiply-add for f32 or f64, off elsewhere.
// On x86 that is FMA: x86-64-v3 and up, an FMA CPU, or +fma, and not
// baseline x86-64, x86-64-v2 or i686. fp_contract_target_arch.k has the
// other architectures; contract_fma_target.k checks the IR.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v2 || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --m32 || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v4 || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mcpu=haswell || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mfeatures=+fma || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 --mfeatures=-fma || true; } | %FileCheck %s --check-prefix=OFF

// ON:      -ffp-contract=on
// ON-NOT:  -ffp-contract=
// OFF:     -ffp-contract=off
// OFF-NOT: -ffp-contract=
