// An `unsafe *T` keeps its C++ type: the may_alias spelling of its pointee
// is typedef sugar, so a Kairo function's symbol is the plain `T*` one
// (`...EPi`), a C++ header's declaration of the same function agrees with
// Kairo's, and C++ code taking `int*` links against both.
// RUN: rm -f %t.exe
// RUN: %kairo %s %S/inputs/raw_caller.cc -O2 -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: sum=12 bump=6 view=3
// RUN: rm -rf %t.ir
// RUN: %kairo %s --emit=llvm-ir --cache-dir %t.ir
// RUN: %FileCheck %s --check-prefix=SYM < %t.ir/ffi_signature_unchanged.ll
// SYM-DAG: define {{.*}}@_ZN{{.*}}23ffi_signature_unchanged4bumpEPi(
// SYM-DAG: define {{.*}}@ksum(ptr
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: CODEGEN C++: {{.*}}ffi_signature_unchanged.k
// CXX: struct __kairo_ma {
// CXX: extern "C" signed int ksum(typename{{ ?}}::__kairo_ma<signed int>::t * p, decltype(sizeof(0)) n)

import std::io

ffi "c++" import "inputs/raw_caller.hh"

ffi "c" fn ksum(p: unsafe *i32, n: usize) -> i32 {
    var s = 0
    for i in 0..n {
        s += p[i]
    }

    return s
}

@no_inline
fn bump(p: unsafe *i32) -> i32 {
    *p += 1
    return *p
}

fn main() -> i32 {
    var a: [i32; 3] = [3, 4, 5]
    var v = 5
    unsafe {
        var p: unsafe *i32 = &a[0] as unsafe *i32
        var b = bump(&v as unsafe *i32)
        io::println(f"sum={call_ksum(p, 3)} bump={b} view={cxx_first(p)}")
    }

    return 0
}
