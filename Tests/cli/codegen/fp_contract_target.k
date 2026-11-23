// Kairo's contraction default follows the target, not the host
// (ClangBackend::_decide_contract): -ffp-contract=on where the target's CPU
// and features give it a fused multiply-add for f32 or f64, off elsewhere.
// One cc1 line per target; contract_fma_target.k checks the IR.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// x86: only with FMA (x86-64-v3 and up, an FMA CPU, +fma).
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v2 || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=i686-linux-musl || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v4 || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mcpu=haswell || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mfeatures=+fma || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 --mfeatures=-fma || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=x86_64-windows-gnu || true; } | %FileCheck %s --check-prefix=OFF

// AArch64 and RISC-V with F/D always have one; 32-bit ARM only with VFPv4;
// wasm never fuses a scalar.
// RUN: { %kairo %s --print-clang-args --target=aarch64-linux-musl || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=arm64-apple-macosx || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=riscv64-linux-musl || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=armv7-linux-musleabihf || true; } | %FileCheck %s --check-prefix=OFF
// RUN: { %kairo %s --print-clang-args --target=armv7-linux-musleabihf --mfeatures=+vfp4d16sp || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=wasm32-wasi || true; } | %FileCheck %s --check-prefix=OFF

// ON:      -ffp-contract=on
// ON-NOT:  -ffp-contract=
// OFF:     -ffp-contract=off
// OFF-NOT: -ffp-contract=
