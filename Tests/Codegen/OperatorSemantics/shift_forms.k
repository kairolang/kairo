// OperatorSemantics: the C++ a shift is spelled as (SHIFT spec §3, §4, §8.5).
// The count is masked to R - 1, R the register width (31 below 32 bits); a
// signed `>>` shifts the left operand sign-extended to R_T. A count proven
// in [0, W) -- a constant, `e & K`, `e % K` on an unsigned e, a range loop's
// binder -- has no mask.

fn masked(a: u8, b: i8, c: u64, d: i64, n: i32) -> i64 {
    var s1 = a << n
    var s2 = b >> n
    var s3 = c << n
    var s4 = d >> n
    var p = a
    p <<= n
    return (s1 as i64) + (s2 as i64) + (s3 as i64) + s4 + (p as i64)
}

fn proven(a: u8, c: u64, k: u32) -> u64 {
    var s5 = a << 3
    var s6 = c >> (k & 63u32)
    var s7 = k >> (k % 32u32)
    var m: u32 = 0
    for i in 0..32 { m |= k << i }
    var q = c
    q >>= 7
    return (s5 as u64) + s6 + (s7 as u64) + (m as u64) + q
}

// The binder is written: the loop proves nothing.
fn written(k: u32) -> u32 {
    var m: u32 = 0
    for var i in 0..32 { i = i + 1; m |= k << i }
    return m
}

fn <T: type> dep_shr(a: T, n: i32) -> T = a >> n

fn main() -> i32 { return dep_shr(-8i8, 1) as i32 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-LABEL: masked({{.*}}) noexcept {
// CHECK: s1 = static_cast<unsigned char>(static_cast<unsigned int>(a) <<(static_cast<unsigned int>(n) & static_cast<unsigned int>(31)));
// CHECK-NEXT: s2 = static_cast<signed char>(static_cast<int>(b) >>(static_cast<unsigned int>(n) & static_cast<unsigned int>(31)));
// CHECK-NEXT: s3 = static_cast<unsigned long{{( long)?}}>(static_cast<unsigned long{{( long)?}}>(c) <<(static_cast<unsigned long{{( long)?}}>(n) & static_cast<unsigned long{{( long)?}}>(63)));
// CHECK-NEXT: s4 = static_cast<signed long{{( long)?}}>(static_cast<signed long{{( long)?}}>(d) >>(static_cast<unsigned long{{( long)?}}>(n) & static_cast<unsigned long{{( long)?}}>(63)));
// CHECK: (p = static_cast<unsigned char>(static_cast<unsigned int>(p) <<(static_cast<unsigned int>(n) & static_cast<unsigned int>(31))));
//
// CHECK-LABEL: proven({{.*}}) noexcept {
// CHECK: s5 = static_cast<unsigned char>(static_cast<unsigned int>(a) << static_cast<unsigned int>(3));
// CHECK-NEXT: s6 = static_cast<unsigned long{{( long)?}}>(static_cast<unsigned long{{( long)?}}>(c) >> static_cast<unsigned long{{( long)?}}>((k &(static_cast<unsigned int>(63)))));
// CHECK-NEXT: s7 = static_cast<unsigned int>(static_cast<unsigned int>(k) >> static_cast<unsigned int>(({
// CHECK: (m |= static_cast<unsigned int>(static_cast<unsigned int>(k) << static_cast<unsigned int>(i)));
// CHECK: (q = static_cast<unsigned long{{( long)?}}>(static_cast<unsigned long{{( long)?}}>(q) >> static_cast<unsigned long{{( long)?}}>(7)));
// CHECK-NOT: & static_cast
// CHECK-LABEL: written({{.*}}) noexcept {
// CHECK: (m |= static_cast<unsigned int>(static_cast<unsigned int>(k) <<(static_cast<unsigned int>(i) & static_cast<unsigned int>(31))));
//
// A duck generic decides per instance: R from T's size, a signed `>>`
// through S, U's signed twin.
// CHECK-LABEL: T dep_shr(T a, signed int n) noexcept {
// CHECK: constexpr auto __kairo_R0 =(sizeof(__kairo_T0) * 8> 128) ? sizeof(__kairo_T0) * 8:((sizeof(__kairo_T0) * 8> 64) ? 128:((sizeof(__kairo_T0) * 8<32) ? 32: sizeof(__kairo_T0) * 8));
// CHECK-NEXT: if constexpr(__is_signed(__kairo_T0)) {
// CHECK-NEXT: using __kairo_S0 = __make_signed(__kairo_U0);
// CHECK-NEXT: return static_cast<__kairo_T0>(static_cast<__kairo_S0>(__kairo_a0) >>(static_cast<__kairo_U0>(__kairo_b0) & static_cast<__kairo_U0>(__kairo_R0 - 1)));
// CHECK-NEXT: }
// CHECK-NEXT: return static_cast<__kairo_T0>(static_cast<__kairo_U0>(__kairo_a0) >>(static_cast<__kairo_U0>(__kairo_b0) & static_cast<__kairo_U0>(__kairo_R0 - 1)));
