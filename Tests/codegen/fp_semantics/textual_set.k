// pch_set.k's split, for a header set that reaches the TU as text: this
// TU's own set (<vector>) is its PCH, so lib.k's set (fp_split.h) is
// `#include`d through phase B's wrapper, which carries the same pragmas.
// lib_mac is inline, so h_mac is compiled here; it keeps C++'s contraction,
// as this file's own k_mac has Kairo's: none on baseline x86-64 (SPLIT),
// which has no fused multiply-add, and the same as C++'s on x86-64-v3
// (FUSE).

ffi "c++" import "vector"
import lib

fn k_mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }

fn main() -> i32 {
    var v: cxx::std::vector<f64>
    v.push_back(lib::lib_mac(1.0, 2.0, 3.0))
    return (v[0] + k_mac(1.0, 2.0, 3.0)) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d %t.v3
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-musl --cache-dir %t.d
// RUN: %FileCheck %s --check-prefixes=CHECK,SPLIT < %t.d/textual_set.ll
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-musl --march=x86-64-v3 --cache-dir %t.v3
// RUN: %FileCheck %s --check-prefixes=CHECK,FUSE < %t.v3/textual_set.ll

// CHECK-LABEL: define {{.*}}@_ZN11textual_set5k_macEddd(
// SPLIT-NOT:   fmuladd
// SPLIT:       fmul double
// SPLIT:       fadd double
// FUSE:        call double @llvm.fmuladd.f64(
// CHECK-LABEL: define {{.*}}@_Z5h_macddd(
// CHECK:       call double @llvm.fmuladd.f64(
