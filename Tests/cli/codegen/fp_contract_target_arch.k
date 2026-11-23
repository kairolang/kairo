// Kairo's contraction default on the architectures other than x86
// (fp_contract_target.k): AArch64 and RISC-V with F and D always have a
// fused multiply-add; 32-bit ARM has one only with VFPv4, which the armv7
// default leaves off; wasm never fuses a scalar.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-aarch64-linux-musl, sysroot-riscv64-linux-musl, sysroot-armv7-linux-musl, sysroot-wasm32-wasi
// RUN: %kairo %s --print-clang-args --target=aarch64-linux-musl | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s --print-clang-args --target=riscv64-linux-musl | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s --print-clang-args --target=armv7-linux-musleabihf | %FileCheck %s --check-prefix=OFF
// RUN: %kairo %s --print-clang-args --target=armv7-linux-musleabihf --mfeatures=+vfp4d16sp | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s --print-clang-args --target=wasm32-wasi | %FileCheck %s --check-prefix=OFF

// ON:      -ffp-contract=on
// ON-NOT:  -ffp-contract=
// OFF:     -ffp-contract=off
// OFF-NOT: -ffp-contract=
