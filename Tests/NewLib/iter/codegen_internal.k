// A chain is one loop in its source. At -O2 and at -O3 each function below
// is that loop and nothing else: no adapter or sink is stored (no alloca), no
// callback or sink is called (no call but an `llvm.` intrinsic), and the
// loop is the one a person would write.
//
//   sized_sum      `filter` is a select inside a vectorized loop
//   sized_vector   the same over a vector, through its slice conversion
//   sized_counted  `enumerate().take(n)` cuts the source once (umin) and
//                  counts with no second exit test in the chain
//   sized_rev      `rev().take_while().count()` walks down from the end
//   sized_find     a consumer that stops early is still one loop
//   sized_collect  one allocation, and a vectorized store loop with no
//                  capacity test and no grow call
//   gen_sum        the generator source: its frame is elided and the loop
//                  is vectorized

import std::iter::*

fn triple(x: i32) -> i32 = x * 3
fn is_even(x: *const i32) -> bool = (*x & 1) == 0
fn weigh(acc: i64, e: (usize, *const i32)) -> i64 = acc + (e.0 as i64) * (*e.1 as i64)
fn not_sentinel(p: *const (*const i32)) -> bool = **p != 5000
fn is_seven(x: *const i32) -> bool = *x == 7

pub fn sized_sum(const s: [const i32;]) -> i32 {
    return iter_slice_(s).copied().map<i32>(triple).filter(is_even).sum()
}

pub fn sized_vector(const v: [i32]) -> i32 {
    var s: [const i32;] = v
    return iter_slice_(s).copied().map<i32>(triple).filter(is_even).sum()
}

pub fn sized_counted(const s: [const i32;], n: usize) -> i64 {
    return iter_slice_(s).enumerate().take(n).fold<i64>(0, weigh)
}

pub fn sized_rev(const s: [const i32;]) -> usize {
    return iter_slice_(s).rev().take_while(not_sentinel).count()
}

pub fn sized_find(const s: [const i32;]) -> bool {
    return iter_slice_(s).copied().map<i32>(triple).any(is_seven)
}

pub fn sized_collect(const s: [const i32;]) -> [i32] {
    return iter_slice_(s).copied().map<i32>(triple).collect<[i32]>()
}

pub fn gen_sum(const s: [const i32;]) -> i32 {
    return iter(s.iter()).copied().map<i32>(triple).filter(is_even).sum()
}

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4]
    var out = sized_collect(v)
    var found = if sized_find(v) => 1 else => 0
    return sized_sum(v) + sized_vector(v) + gen_sum(v) + sized_counted(v, 2) as i32 + sized_rev(v) as i32 + out[3] + found - 54 - 2 - 4 - 12
}

// CHECK-LABEL: define {{.*}}9sized_sum
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: select <{{[0-9]+}} x i1>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}12sized_vector
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: select <{{[0-9]+}} x i1>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}13sized_counted
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: call {{.*}}@llvm.umin.i64
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}9sized_rev
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}10sized_find
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}13sized_collect
// CHECK-NOT: alloca
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}9vec_alloc
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: store <{{[0-9]+}} x i32>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}7gen_sum
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK-NOT: alloca
// CHECK: select <{{[0-9]+}} x i1>
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new -O2 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.ll
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new -O3 --target=x86_64-linux-gnu --emit=llvm-ir %s -o %t.O3.ll --cache-dir %t.d
// RUN: %FileCheck %s --input-file=%t.O3.ll
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
