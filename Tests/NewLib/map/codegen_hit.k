// The lookup paths of HashMap<u64, u64> at -O2 on x86-64: a hit or a miss
// makes no call at all and hashes with two multiplies, and iteration is a
// pointer walk that vectorizes.

@no_inline
pub fn probe(const m: {u64: u64}, k: u64) -> u64 {
    var *e? = m.get(k)
    if e? { return *e }
    return 7
}

@no_inline
pub fn has(const s: {u64}, k: u64) -> bool {
    return s.contains(k)
}

@no_inline
pub fn sum(const m: {u64: u64}) -> u64 {
    var acc: u64 = 0
    for (k, v) in m { acc += v }
    return acc
}

fn main() -> i32 {
    var m: {u64: u64}
    var s: {u64}
    for var i: u64 = 0; i < 100; i += 1 {
        m.insert(i, i)
        s.insert(i)
    }
    return (probe(m, 5) + sum(m)) as i32 + (has(s, 3) as i32)
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 --target=x86_64-linux-gnu --emit asm --cache-dir %t.d -o %t.s
// RUN: %FileCheck %s --check-prefix=PROBE < %t.s
// RUN: %FileCheck %s --check-prefix=HAS < %t.s
// RUN: %FileCheck %s --check-prefix=SUM < %t.s
// PROBE-LABEL: {{^}}_ZN11codegen_hit5probe{{.*}}:
// PROBE-NOT: call
// PROBE: mulq
// PROBE-NOT: call
// PROBE: mulq
// PROBE-NOT: call
// PROBE: .Lfunc_end
// HAS-LABEL: {{^}}_ZN11codegen_hit3has{{.*}}:
// HAS-NOT: call
// HAS: .Lfunc_end
// SUM-LABEL: {{^}}_ZN11codegen_hit3sum{{.*}}:
// SUM-NOT: call
// SUM: .Lfunc_end
