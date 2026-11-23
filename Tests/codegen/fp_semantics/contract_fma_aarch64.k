// AArch64 always has a fused multiply-add, so Kairo contracts there by
// default (contract_fma_target.k has the x86-64 cases, where it depends on
// the CPU), and --fp-contract=off still turns it off.

pub fn mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-aarch64-linux-musl
// RUN: rm -rf %t.dfl %t.off
// RUN: %kairo %s --emit=llvm-ir -O1 --target=aarch64-linux-musl --cache-dir %t.dfl
// RUN: %FileCheck %s --check-prefix=FUSE < %t.dfl/contract_fma_aarch64.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=aarch64-linux-musl --fp-contract=off --cache-dir %t.off
// RUN: %FileCheck %s --check-prefix=SPLIT < %t.off/contract_fma_aarch64.ll

// FUSE-LABEL: define {{.*}}@_ZN20contract_fma_aarch643macEddd(
// FUSE:       call double @llvm.fmuladd.f64(

// SPLIT-NOT:   fmuladd
// SPLIT-LABEL: define {{.*}}@_ZN20contract_fma_aarch643macEddd(
// SPLIT:       fmul double
// SPLIT:       fadd double
