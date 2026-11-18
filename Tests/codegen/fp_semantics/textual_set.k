// pch_set.k's split, for a header set that reaches the TU as text: this
// TU's own set (<vector>) is its PCH, so lib.k's set (fp_split.h) is
// `#include`d through phase B's wrapper, which carries the same pragmas.
// lib_mac is inline, so h_mac is compiled here; it keeps contraction while
// this file's own k_mac does not.

ffi "c++" import "vector"
import lib

fn k_mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }

fn main() -> i32 {
    var v: cxx::std::vector<f64>
    v.push_back(lib::lib_mac(1.0, 2.0, 3.0))
    return (v[0] + k_mac(1.0, 2.0, 3.0)) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O0 --cache-dir %t.d
// RUN: %FileCheck %s < %t.d/textual_set.ll

// CHECK-LABEL: define {{.*}}@_ZN11textual_set5k_macEddd(
// CHECK-NOT:   fmuladd
// CHECK:       fmul double
// CHECK:       fadd double
// CHECK-LABEL: define {{.*}}@_Z5h_macddd(
// CHECK:       call double @llvm.fmuladd.f64(
