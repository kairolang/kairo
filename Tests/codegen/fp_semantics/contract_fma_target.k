// Kairo contracts a multiply and an add within one expression where the
// target can fuse them into one instruction, and not where it cannot: there
// a contracted pair computes what the two operations compute, and only
// hides them from the optimizer. Baseline x86-64 has no fused multiply-add
// (SPLIT); x86-64-v3, a CPU with FMA and a feature list that turns it on
// have one (FUSE), and taking the feature back out of x86-64-v3 leaves none.
// An explicit --fp-contract decides on every target.

pub fn mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.base %t.v3 %t.cpu %t.feat %t.nofma %t.v3off %t.baseon
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --cache-dir %t.base
// RUN: %FileCheck %s --check-prefix=SPLIT < %t.base/contract_fma_target.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --march=x86-64-v3 --cache-dir %t.v3
// RUN: %FileCheck %s --check-prefix=FUSE < %t.v3/contract_fma_target.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --mcpu=znver3 --cache-dir %t.cpu
// RUN: %FileCheck %s --check-prefix=FUSE < %t.cpu/contract_fma_target.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --mfeatures=+fma --cache-dir %t.feat
// RUN: %FileCheck %s --check-prefix=FUSE < %t.feat/contract_fma_target.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --march=x86-64-v3 --mfeatures=-fma --cache-dir %t.nofma
// RUN: %FileCheck %s --check-prefix=SPLIT < %t.nofma/contract_fma_target.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --march=x86-64-v3 --fp-contract=off --cache-dir %t.v3off
// RUN: %FileCheck %s --check-prefix=SPLIT < %t.v3off/contract_fma_target.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --fp-contract=on --cache-dir %t.baseon
// RUN: %FileCheck %s --check-prefix=FUSE < %t.baseon/contract_fma_target.ll

// FUSE-LABEL: define {{.*}}@_ZN19contract_fma_target3macEddd(
// FUSE:       call double @llvm.fmuladd.f64(

// SPLIT-NOT:   fmuladd
// SPLIT-LABEL: define {{.*}}@_ZN19contract_fma_target3macEddd(
// SPLIT:       fmul double
// SPLIT:       fadd double
// SPLIT-NOT:   fmuladd
