// A lookup in a `{u64: u64}` or a `{u64}` from a user function holds no
// call at -O2 on x86-64: the key's hash is two multiplies and the probe is
// inline.

fn m_get(const m: {u64: u64}, k: u64) -> u64 {
    var *p? = m.get(k)
    if p? {
        return *p
    }

    return 0
}

fn m_has(const m: {u64: u64}, k: u64) -> bool {
    return m.contains(k)
}

fn m_size(const m: {u64: u64}) -> usize {
    return m.size()
}

fn h_has(const s: {u64}, k: u64) -> bool {
    return s.contains(k)
}

fn main() -> i32 {
    return 0
}

// CHECK-LABEL: define {{.*}}5m_get
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}5m_has
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}6m_size
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}
// CHECK-LABEL: define {{.*}}5h_has
// CHECK-NOT: {{(call|invoke) [^@]*@[^l]}}
// CHECK: {{^}}}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll
