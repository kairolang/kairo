// A user function on a slice holds no call at -O2 on x86-64 other than the
// shared bounds failure of an index.

fn sl_at(sl: [const i32;], i: usize) -> i32 {
    return sl[i]
}

fn sl_size(sl: [const i32;]) -> usize {
    return sl.size()
}

fn sl_set(sl: [i32;], i: usize, x: i32) {
    sl[i] = x
}

fn main() -> i32 {
    return 0
}

// CHECK-LABEL: define {{.*}}5sl_at
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}index_fail
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}7sl_size
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}6sl_set
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}index_fail
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll
