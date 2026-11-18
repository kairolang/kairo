// An explicit FP flag applies to Kairo code and ffi header code alike, as it
// would to a C/C++ input: the header pragmas restore clang++'s defaults only
// where the user gave no flag (FlagTranslator::header_fp_pragmas). On glibc,
// where C++ has errno: -ffast-math drops it for the header too, while
// --fp-model=strict keeps it there (strict says nothing about errno) and
// Kairo code still has none. Same code as pch_set.k.

ffi "c++" import "fp_split.h"

fn k_mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }
fn k_sqrt(x: f64) -> f64 { return sqrt(x) }

fn main() -> i32 {
    var r = k_mac(1.0, 2.0, 3.0) + k_sqrt(4.0) + h_mac(1.0, 2.0, 3.0) + h_sqrt(4.0) + t_mac<f64>(1.0, 2.0, 3.0)
    return r as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.on %t.fast %t.ffm %t.strict
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --fp-contract=on --cache-dir %t.on
// RUN: %FileCheck %s --check-prefix=ON < %t.on/user_flags.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --fp-contract=fast --cache-dir %t.fast
// RUN: %FileCheck %s --check-prefix=FAST < %t.fast/user_flags.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu -ffast-math --cache-dir %t.ffm
// RUN: %FileCheck %s --check-prefix=FFM < %t.ffm/user_flags.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --fp-model=strict --cache-dir %t.strict
// RUN: %FileCheck %s --check-prefix=STRICT < %t.strict/user_flags.ll

// --fp-contract=on: Kairo fuses too; the header keeps errno.
// ON-LABEL: define {{.*}}@_ZN10user_flags5k_macEddd(
// ON:       call double @llvm.fmuladd.f64(
// ON-LABEL: define {{.*}}@_ZN10user_flags6k_sqrtEd(
// ON:       call double @llvm.sqrt.f64(
// ON-LABEL: define {{.*}}@_Z5h_macddd(
// ON:       call double @llvm.fmuladd.f64(
// ON-LABEL: define {{.*}}@_Z6h_sqrtd(
// ON:       call double @sqrt(

// --fp-contract=fast: every operation carries `contract`, both sides.
// FAST-LABEL: define {{.*}}@_ZN10user_flags5k_macEddd(
// FAST:       fmul contract double
// FAST:       fadd contract double
// FAST-LABEL: define {{.*}}@_Z5h_macddd(
// FAST:       fmul contract double
// FAST:       fadd contract double
// FAST-LABEL: define {{.*}}@_Z5t_macIdET_S0_S0_S0_(
// FAST:       fmul contract double

// -ffast-math: fast everywhere, and the header's sqrt sets no errno.
// FFM-LABEL: define {{.*}}@_ZN10user_flags5k_macEddd(
// FFM:       fmul fast double
// FFM-LABEL: define {{.*}}@_Z5h_macddd(
// FFM:       fmul fast double
// FFM-LABEL: define {{.*}}@_Z6h_sqrtd(
// FFM-NOT:   call {{.*}}@sqrt(
// FFM:       call fast double @llvm.sqrt.f64(

// --fp-model=strict: constrained operations on both sides; errno only in
// the header.
// STRICT-LABEL: define {{.*}}@_ZN10user_flags5k_macEddd(
// STRICT:       @llvm.experimental.constrained.fmul.f64(
// STRICT-LABEL: define {{.*}}@_ZN10user_flags6k_sqrtEd(
// STRICT:       @llvm.experimental.constrained.sqrt.f64(
// STRICT-LABEL: define {{.*}}@_Z5h_macddd(
// STRICT:       @llvm.experimental.constrained.fmul.f64(
// STRICT-LABEL: define {{.*}}@_Z6h_sqrtd(
// STRICT:       call double @sqrt(
