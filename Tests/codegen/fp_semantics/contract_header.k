// An ffi C++ header region keeps what clang++ gives C++ on the target while
// Kairo contracts by default too: the header's a * b + c fuses (h_mac and
// the template t_mac), and on glibc the header's sqrt keeps errno where
// Kairo's has none. Given explicitly, --fp-contract=off applies to the header
// as it would to a C++ input: nothing fuses on either side, on glibc (where
// float_control(precise, on) restores errno and sets contraction on, so the
// contract pragma after it is still needed) and on musl.

ffi "c++" import "fp_split.h"

fn k_mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }
fn k_sqrt(x: f64) -> f64 { return sqrt(x) }

fn main() -> i32 {
    var r = k_mac(1.0, 2.0, 3.0) + k_sqrt(4.0) + h_mac(1.0, 2.0, 3.0) + h_sqrt(4.0) + t_mac<f64>(1.0, 2.0, 3.0)
    return r as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.musl %t.gnu %t.gnuoff %t.musloff
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-musl --cache-dir %t.musl
// RUN: %FileCheck %s --check-prefixes=ON,MUSL < %t.musl/contract_header.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.gnu
// RUN: %FileCheck %s --check-prefixes=ON,GNU < %t.gnu/contract_header.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --fp-contract=off --cache-dir %t.gnuoff
// RUN: %FileCheck %s --check-prefix=OFF < %t.gnuoff/contract_header.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-musl --fp-contract=off --cache-dir %t.musloff
// RUN: %FileCheck %s --check-prefix=OFF < %t.musloff/contract_header.ll

// ON-LABEL: define {{.*}}@_ZN15contract_header5k_macEddd(
// ON:       call double @llvm.fmuladd.f64(
// ON-LABEL: define {{.*}}@_ZN15contract_header6k_sqrtEd(
// ON:       call double @llvm.sqrt.f64(
// ON-LABEL: define {{.*}}@_Z5h_macddd(
// ON:       call double @llvm.fmuladd.f64(
// ON-LABEL: define {{.*}}@_Z6h_sqrtd(
// MUSL:     call double @llvm.sqrt.f64(
// GNU:      call double @sqrt(
// ON-LABEL: define {{.*}}@_Z5t_macIdET_S0_S0_S0_(
// ON:       call double @llvm.fmuladd.f64(

// OFF-NOT:   fmuladd
// OFF-LABEL: define {{.*}}@_ZN15contract_header5k_macEddd(
// OFF:       fmul double
// OFF-LABEL: define {{.*}}@_Z5h_macddd(
// OFF:       fmul double
// OFF-LABEL: define {{.*}}@_Z5t_macIdET_S0_S0_S0_(
// OFF:       fmul double
// OFF-NOT:   fmuladd
