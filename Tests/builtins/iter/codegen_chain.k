// A chain over a slice costs what its loop costs. At -O2 each function
// below is its loops and nothing else: the adapter structs are never stored
// (no alloca), and the `fn` callbacks are the named functions, inlined (no
// call of any kind, direct or through a pointer, other than an `llvm.`
// intrinsic).

import std::iter::*

fn triple(x: i32) -> i32 = x * 3
fn is_even(x: *const i32) -> bool = (*x & 1) == 0
fn weigh(acc: i64, e: (usize, *const i32)) -> i64 = acc + (e.0 as i64) * (*e.1 as i64)
fn below(p: *const i32) -> bool = *p < 1000

pub fn chain_slice(const s: [const i32;]) -> i32 {
    return iter(s.iter()).copied().map<i32>(triple).filter(is_even).sum()
}

pub fn chain_vector(const v: [i32]) -> i32 {
    return iter(v.iter()).copied().map<i32>(triple).filter(is_even).sum()
}

pub fn chain_counted(const s: [const i32;], n: usize) -> i64 {
    return iter(s.iter()).enumerate().take(n).fold<i64>(0, weigh)
}

pub fn chain_mapped(const s: [const i32;]) -> i32 {
    return iter(s.iter()).copied().map<i32>(triple).sum()
}

pub fn chain_prefix(const s: [const i32;]) -> usize {
    return iter(s.iter()).copied().skip(1).take_while(below).step_by(2).count()
}

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4]
    return chain_slice(v) + chain_vector(v) + chain_mapped(v) + chain_counted(v, 2) as i32 + chain_prefix(v) as i32 - 70
}

// CHECK-LABEL: define {{.*}}11chain_slice
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}12chain_vector
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}13chain_counted
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}12chain_mapped
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: mul <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}12chain_prefix
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new -O2 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.ll
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
