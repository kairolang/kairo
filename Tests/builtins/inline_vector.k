// A user function on a `[i32]` holds no call at -O2 on x86-64 other than
// the documented cold ones: size, is_empty and clear have none, an index
// calls only the shared bounds failure, and push calls only the grower.

fn v_size(const v: [i32]) -> usize {
    return v.size()
}

fn v_empty(const v: [i32]) -> bool {
    return v.is_empty()
}

fn v_at(const v: [i32], i: usize) -> i32 {
    return v[i]
}

fn v_set(@inout v: [i32], i: usize, x: i32) {
    v[i] = x
}

fn v_push(@inout v: [i32], x: i32) {
    v.push(x)
}

fn v_clear(@inout v: [i32]) {
    v.clear()
}

fn main() -> i32 {
    return 0
}

// CHECK-LABEL: define {{.*}}6v_size
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}7v_empty
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}4v_at
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}index_fail
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}5v_set
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}index_fail
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}6v_push
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: call {{.*}}grow_bytes
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}7v_clear
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll
