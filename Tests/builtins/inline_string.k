// A user function that reads a string through its accessors holds no call
// at -O2 on x86-64: size, data, is_empty and capacity are a load and a few
// instructions each, a literal is two constants, and a prefix test against
// a short literal is compared in place.

fn s_size(const s: string) -> usize {
    return s.size()
}

fn s_data(const s: string) -> *const u8 {
    return s.data()
}

fn s_empty(const s: string) -> bool {
    return s.is_empty()
}

fn s_cap(const s: string) -> usize {
    return s.capacity()
}

fn s_lit() -> string {
    return "hello"
}

fn s_prefix(const s: string) -> bool {
    return s.starts_with("ab")
}

fn main() -> i32 {
    return 0
}

// A callee that is not an LLVM intrinsic.
// CHECK-LABEL: define {{.*}}6s_size
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}6s_data
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}7s_empty
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}5s_cap
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}5s_lit
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}8s_prefix
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll
