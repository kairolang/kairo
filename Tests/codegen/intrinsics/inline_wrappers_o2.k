// The builtin intrinsic wrappers are inlined into user code at -O2, the
// generic ones included: an instance the builtin module also names is homed
// there (`extern template` here), and is still inlinable because a template
// definition is C++ `inline`. Each user function below is free of calls into
// `builtin` (the memory family's own libcalls aside); the run checks that
// the results are unchanged.
pub fn k_mem(d: unsafe *u8, s: unsafe *const u8, n: usize) -> i32 {
    __builtin_copy(d, s, n)
    return __builtin_compare_mem(d, s, n)
}

pub fn k_move(d: unsafe *u8, s: unsafe *const u8, n: usize) {
    __builtin_move_mem(d, s, n)
    __builtin_set_mem(d, 0 as byte, 1)
}

pub fn k_ari(a: u64, b: u64) -> u64 {
    var r: u64 = 0
    var x = __builtin_add_overflow<u64>(a, b, &r)
    var y = __builtin_sub_overflow<u64>(r, b, &r)
    var z = __builtin_mul_overflow<u64>(r, a, &r)
    if x || y || z { return 0 }
    return r
}

pub fn k_bits(a: u64) -> u32 {
    return __builtin_clz(a) + __builtin_ctz(a) + __builtin_popcount(a) + (__builtin_bswap(a) >> 56) as u32 + (__builtin_rotl(a, 3) & 1) as u32
}

pub fn k_cast(f: f64) -> u64 { return __builtin_bitcast<u64, f64>(f) ^ f.to_bits() ^ 1 }

pub fn k_trait() -> bool { return __builtin_is_trivially_relocatable<u64>() && __builtin_is_same<u64, u64>() }

pub fn k_atomic(p: *u64) -> u64 {
    return __builtin_atomic_fetch_add<u64>(p, 1, MemoryOrder::SeqCst) + __builtin_atomic_load<u64>(p, MemoryOrder::Acquire)
}

fn main() -> i32 {
    var a: [u8; 4] = [1, 2, 3, 4]
    var b: [u8; 4] = [0, 0, 0, 0]
    if k_mem(unsafe &b[0], unsafe &a[0], 4) != 0 || b[3] != 4 { return 1 }
    k_move(unsafe &b[0], unsafe &a[1], 3)
    if b[0] != 0 || b[1] != 3 { return 2 }
    if k_ari(3, 4) != 9 { return 3 }
    if k_bits(0x10) != 80 { return 4 }
    if k_cast(1.5) != 1 { return 5 }
    if !k_trait() { return 6 }
    var c: u64 = 5
    if k_atomic(&c) != 11 { return 7 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --emit asm --emit-scope=inputs -c --target x86_64-linux-gnu -o %t.d/w.s
// RUN: %FileCheck %s < %t.d/w.s
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o25k_mem{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_ZN7builtin
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o26k_move{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_ZN7builtin
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o25k_ari{{.*}}:
// CHECK-NOT: {{call|jmp}}
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o26k_bits{{.*}}:
// CHECK-NOT: {{call|jmp}}
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o26k_cast{{.*}}:
// CHECK-NOT: {{call|jmp}}
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o27k_trait{{.*}}:
// CHECK-NOT: {{call|jmp}}
// CHECK: .cfi_endproc
// CHECK-LABEL: {{^}}_ZN{{[0-9]+}}inline_wrappers_o28k_atomic{{.*}}:
// CHECK-NOT: {{call|jmp}}
// CHECK: .cfi_endproc

// REQUIRES: clang
// RUN: rm -rf %t.run
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.run
// RUN: %t.exe
