// A chain is one loop in its source. At -O2 and at -O3 each function below
// is that loop and nothing else: no adapter or sink is stored (no alloca), no
// callback or sink is called (no call but an `llvm.` intrinsic), and the
// loop is the one a person would write.
//
//   chain_sum      `filter` is a select inside a vectorized loop
//   chain_vector   the same over a vector
//   chain_counted  `enumerate().take(n)` cuts the source once and counts
//                  with no second exit test in the chain
//   chain_rev      `rev().take_while().count()` walks down from the end
//   chain_find     a consumer that stops early is still one loop
//   chain_collect  one allocation, and a vectorized store loop with no
//                  capacity test and no grow call
//   chain_back     `next_back()` on the chain itself

import std::iter::*

fn triple(x: i32) -> i32 = x * 3
fn is_even(x: *const i32) -> bool = (*x & 1) == 0
fn weigh(acc: i64, e: (usize, *const i32)) -> i64 = acc + (e.0 as i64) * (*e.1 as i64)
fn not_sentinel(p: *const (*const i32)) -> bool = **p != 5000
fn is_seven(x: *const i32) -> bool = *x == 7

pub fn chain_sum(const s: [const i32;]) -> i32 {
    return iter(s.iter()).copied().map<i32>(triple).filter(is_even).sum()
}

pub fn chain_vector(const v: [i32]) -> i32 {
    return iter(v.iter()).copied().map(triple).filter(is_even).sum()
}

pub fn chain_counted(const s: [const i32;], n: usize) -> i64 {
    return iter(s.iter()).enumerate().take(n).fold<i64>(0, weigh)
}

pub fn chain_rev(const s: [const i32;]) -> usize {
    return iter(s.iter()).rev().take_while(not_sentinel).count()
}

pub fn chain_find(const s: [const i32;]) -> bool {
    return iter(s.iter()).copied().map<i32>(triple).any(is_seven)
}

pub fn chain_collect(const s: [const i32;]) -> [i32] {
    return iter(s.iter()).copied().map<i32>(triple).collect<[i32]>()
}

pub fn chain_back(const s: [const i32;]) -> i32 {
    var c = iter(s.iter()).copied().map(triple)
    var total: i32 = 0
    loop {
        var x? = c.next_back()
        if !x? {
            return total
        }

        total += unwrap!(x)
    }
}

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4]
    var out = chain_collect(v)
    var found = if chain_find(v) => 1 else => 0
    return chain_sum(v) + chain_vector(v) + chain_back(v) - 12 + chain_counted(v, 2) as i32 + chain_rev(v) as i32 + out[3] + found - 54 - 2 - 4 - 12
}

// CHECK-LABEL: define {{.*}}9chain_sum
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: select <{{[0-9]+}} x i1>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}12chain_vector
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: select <{{[0-9]+}} x i1>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}13chain_counted
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}9chain_rev
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}10chain_find
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}13chain_collect
// CHECK-NOT: alloca
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}9vec_alloc
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: store <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}10chain_back
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new -O2 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.ll
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new -O3 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.O3.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.O3.ll
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
