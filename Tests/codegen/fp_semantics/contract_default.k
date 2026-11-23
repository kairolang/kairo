// Kairo contracts by default where the target has a fused multiply-add
// (x86-64-v3 here), as clang does C++ (-ffp-contract=on): a multiply and an
// add within one expression may fuse into one rounding (llvm.fmuladd),
// never across statements. On a target with none (baseline x86-64) the
// default rounds every operation on its own, as --fp-contract=off and
// --fp-model=strict do everywhere; --fp-contract=fast marks every operation
// `contract`, across statements too.

pub fn mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }

pub fn split(a: f64, b: f64, c: f64) -> f64 {
    var t = a * b
    return t + c
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.dfl %t.fma %t.off %t.strict %t.fast
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --cache-dir %t.dfl
// RUN: %FileCheck %s --check-prefix=DFL < %t.dfl/contract_default.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --march=x86-64-v3 --cache-dir %t.fma
// RUN: %FileCheck %s --check-prefix=FMA < %t.fma/contract_default.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --fp-contract=off --cache-dir %t.off
// RUN: %FileCheck %s --check-prefix=OFF < %t.off/contract_default.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --fp-model=strict --cache-dir %t.strict
// RUN: %FileCheck %s --check-prefix=STRICT < %t.strict/contract_default.ll
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-musl --fp-contract=fast --cache-dir %t.fast
// RUN: %FileCheck %s --check-prefix=FAST < %t.fast/contract_default.ll

// DFL-LABEL: define {{.*}}@_ZN16contract_default3macEddd(
// DFL-NOT:   fmuladd
// DFL:       fmul double
// DFL:       fadd double
// DFL-LABEL: define {{.*}}@_ZN16contract_default5splitEddd(
// DFL-NOT:   fmuladd
// DFL:       fmul double
// DFL:       fadd double
// DFL:       ret double

// FMA-LABEL: define {{.*}}@_ZN16contract_default3macEddd(
// FMA:       call double @llvm.fmuladd.f64(
// FMA-LABEL: define {{.*}}@_ZN16contract_default5splitEddd(
// FMA-NOT:   fmuladd
// FMA:       fmul double
// FMA:       fadd double
// FMA:       ret double

// OFF-NOT:   fmuladd
// OFF-LABEL: define {{.*}}@_ZN16contract_default3macEddd(
// OFF:       fmul double
// OFF:       fadd double
// OFF-NOT:   fmuladd

// STRICT-NOT:   fmuladd
// STRICT-LABEL: define {{.*}}@_ZN16contract_default3macEddd(
// STRICT:       @llvm.experimental.constrained.fmul.f64(
// STRICT:       @llvm.experimental.constrained.fadd.f64(
// STRICT-NOT:   fmuladd

// FAST-LABEL: define {{.*}}@_ZN16contract_default3macEddd(
// FAST:       fmul contract double
// FAST:       fadd contract double
// FAST-LABEL: define {{.*}}@_ZN16contract_default5splitEddd(
// FAST:       fmul contract double
// FAST:       fadd contract double
