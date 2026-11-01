// OperatorSemantics: a duck `<T: type>` operand's integer arm keeps every
// check the concrete forms have, pinned at T = i32 and at narrow types:
// `/` and `%` test the zero divisor and `MIN / -1` inside the integral
// branch, and a shift masks its count with `sizeof(T) * 8 - 1` (so a u8
// shifts by 9 as by 1, an i64 by 65 as by 1).

import std::io::*

fn <T: type> quot(a: T, b: T) -> T = a / b
fn <T: type> rem(a: T, b: T) -> T = a % b
fn <T: type> shl(a: T, n: i32) -> T = a << n
fn <T: type> shr(a: T, n: i32) -> T = a >> n

fn main() -> i32 {
    var imin: i32 = -2147483647 - 1
    var m1: i32 = -1
    println(f"{quot(imin, m1)} {rem(imin, m1)} {quot(7, 2)} {rem(-7, 2)}")   // I32DIV: -2147483648 0 3 -1
    var bmin: i8 = -128
    var bm1: i8 = -1
    println(f"{quot(bmin, bm1)} {rem(bmin, bm1)}")                         // I8DIV: -128 0
    var one32: i32 = 1
    println(f"{shl(one32, 33)} {shr(imin, 33)}")                          // I32SH: 2 -1073741824
    var one8: u8 = 1
    var hi8: i8 = -128
    println(f"{shl(one8, 9)} {shr(hi8, 9)} {shl(one8, 7)}")              // I8SH: 2 -64 128
    var one64: i64 = 1
    println(f"{shl(one64, 65)}")                                           // I64SH: 2
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=I32DIV,I8DIV,I32SH,I8SH,I64SH
// The checks sit inside the integral arm, and the mask is the width's.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}dependent_edges_run.k
// CXX: template<class T> T quot(T a, T b) noexcept {
// CXX: if constexpr(__is_integral(__kairo_T0) &&(!__is_same(__kairo_T0, bool))) {
// CXX-NEXT: using __kairo_U0 =
// CXX-NEXT: if(__builtin_expect(__kairo_b0 == 0, 0))::kairo_rt_div_zero();
// CXX-NEXT: if constexpr(__is_signed(__kairo_T0)) {
// CXX-NEXT: if(__kairo_b0 == static_cast<__kairo_T0>(- 1)) {
// CXX: template<class T> T shl(T a, signed int n) noexcept {
// CXX: (static_cast<__kairo_U0>(__kairo_b0) & static_cast<__kairo_U0>(sizeof(__kairo_T0) * 8 - 1))
