// The builtin library's small generic wrappers over compiler intrinsics
// (to_bits, __builtin_bitcast, the overflow-checked arithmetic) are defined
// where an importing module sees them, so at -O2 each use is the instruction
// itself and not a call into the builtin object.

@no_inline fn bits_of(f: f32) -> u32 { return f.to_bits() }
@no_inline fn bitcast32(f: f32) -> u32 { return __builtin_bitcast<u32>(f) }
@no_inline fn bitcast64(f: f64) -> u64 { return __builtin_bitcast<u64>(f) }
@no_inline fn mul_overflows(a: i32, b: i32) -> bool {
    var r: i32 = 0
    return __builtin_mul_overflow(a, b, &r)
}
@no_inline fn add_overflows(a: i32, b: i32) -> bool {
    var r: i32 = 0
    return __builtin_add_overflow(a, b, &r)
}

fn main() -> i32 {
    var bad = 0
    if bits_of(1.5) != 0x3FC00000 { bad = bad + 1 }
    if bitcast32(1.5) != 0x3FC00000 { bad = bad + 2 }
    if bitcast64(2.0) != 0x4000000000000000 { bad = bad + 4 }
    if mul_overflows(3, 4) || !mul_overflows(65536, 65536) { bad = bad + 8 }
    if add_overflows(3, 4) || !add_overflows(2147483647, 1) { bad = bad + 16 }
    return bad
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.e
// RUN: %t.exe
// RUN: %kairo %s -O2 --emit=asm --target=x86_64-linux-gnu --cache-dir %t.d/asm
// RUN: grep -vE '^[[:space:]]*(\.|#)|^\.L' %t.d/asm/builtin_intrinsics_inline_o2.s | %FileCheck %s
// CHECK-LABEL: {{[0-9]+}}7bits_of{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_Z
// CHECK: ret
// CHECK-LABEL: {{[0-9]+}}9bitcast32{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_Z
// CHECK: ret
// CHECK-LABEL: {{[0-9]+}}9bitcast64{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_Z
// CHECK: ret
// CHECK-LABEL: {{[0-9]+}}13mul_overflows{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_Z
// CHECK: ret
// CHECK-LABEL: {{[0-9]+}}13add_overflows{{.*}}:
// CHECK-NOT: {{call|jmp}}{{.*}}_Z
// CHECK: ret
