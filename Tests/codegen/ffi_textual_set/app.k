// lib.k's header set reaches this TU as text: this TU's own set (<vector>)
// is its PCH, and lib's inline bodies are compiled here, so phase B's
// wrapper replays lib's imports. Each kind once:
//   - c_add.h, `ffi "c"` and beside lib.k: by its path, inside extern "C",
//     or c_add would be C++-mangled and the link against c_add.c fails;
//   - sub/deep.h, found only through -I: by name (HeaderSet::replay_include);
//   - c_mac, C code in that header: C's contraction (fmuladd) inside the
//     header FP pragmas, where this file's own a * b + c is not fused.

ffi "c++" import "vector"
import lib

fn k_mac(a: f64, b: f64, c: f64) -> f64 { return a * b + c }

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(lib::lib_sum(20, 1))
    var f = lib::lib_mac(1.0, 2.0, 3.0) + k_mac(1.0, 2.0, 3.0)
    return v[0] + (f as i32) - 10
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.ir && mkdir -p %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s %S/c_add.c -I %S/inc -o %t.exe --cache-dir %t.d/k
// The C file is compiled and linked by the same kairo invocation.
// RUN: %t.exe; test $? -eq 42

// RUN: %kairo %s -I %S/inc --emit=llvm-ir -O0 --cache-dir %t.ir
// RUN: %FileCheck %s < %t.ir/app.ll
// RUN: %FileCheck %s --check-prefix=SYM < %t.ir/app.ll
// SYM-DAG: declare i32 @c_add(i32 noundef, i32 noundef)
// SYM-DAG: define linkonce_odr {{.*}}@_Z10deep_twicei(
// CHECK-LABEL: define {{.*}}@_ZN3app5k_macEddd(
// CHECK-NOT:   fmuladd
// CHECK:       fmul double
// CHECK-LABEL: define internal {{.*}}@_ZL5c_macddd(
// CHECK:       call double @llvm.fmuladd.f64(
