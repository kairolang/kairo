// Kairo's FP semantics are its own, not C++'s, though both compile in one
// clang TU. Kairo code: no contraction, no errno from math functions
// (FlagTranslator::kairo_fp_cc1). The ffi header's code, including a
// template Kairo instantiates: what clang++ gives C++ on the target
// (contraction on; errno where the target's C++ default has it, glibc yes,
// musl no), restored by the pragmas around the header region
// (FlagTranslator::header_fp_pragmas). Here the header is this TU's own set,
// so it arrives as phase A's PCH; textual_set.k covers a set included as
// text.

ffi "c++" import "fp_split.h"

fn k_mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }
fn k_sqrt(x: f64) -> f64 { return sqrt(x) }

fn main() -> i32 {
    var r = k_mac(1.0, 2.0, 3.0) + k_sqrt(4.0) + h_mac(1.0, 2.0, 3.0) + h_sqrt(4.0) + t_mac<f64>(1.0, 2.0, 3.0)
    return r as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.musl %t.gnu
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-musl --cache-dir %t.musl
// RUN: %FileCheck %s --check-prefixes=ALL,MUSL < %t.musl/pch_set.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.gnu
// RUN: %FileCheck %s --check-prefixes=ALL,GNU < %t.gnu/pch_set.ll

// ALL-LABEL: define {{.*}}@_ZN7pch_set5k_macEddd(
// ALL-NOT:   fmuladd
// ALL:       fmul double
// ALL:       fadd double
// ALL-LABEL: define {{.*}}@_ZN7pch_set6k_sqrtEd(
// ALL:       call double @llvm.sqrt.f64(
// ALL-LABEL: define {{.*}}@_Z5h_macddd(
// ALL:       call double @llvm.fmuladd.f64(
// ALL-LABEL: define {{.*}}@_Z6h_sqrtd(
// MUSL:      call double @llvm.sqrt.f64(
// GNU:       call double @sqrt(
// ALL-LABEL: define {{.*}}@_Z5t_macIdET_S0_S0_S0_(
// ALL:       call double @llvm.fmuladd.f64(
