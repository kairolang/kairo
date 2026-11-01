// OperatorSemantics: arithmetic on a duck `<T: type>` parameter is decided
// per instance. An integer T wraps (the if-constexpr arm on its carrier);
// any other T keeps its own operator, so a float adds as a float and a
// record calls its `op +`.

import std::io::*

struct P {
    var v: f64
    fn op + (self, o: P) -> P { return P { v: self.v + o.v } }
}

fn <T: type> add(a: T, b: T) -> T = a + b
fn <T: type> quot(a: T, b: T) -> T = a / b
fn <T: type> shl(a: T, n: i32) -> T = a << n
fn <T: type> bump(a: T) -> T {
    var x = a
    x += a
    x++
    return -x
}

fn main() -> i32 {
    var p = add(P { v: 1.5 }, P { v: 2.0 })
    println(f"{add(2147483647, 1)} {add(1.5, 2.25)} {p.v}")    // ADD: -2147483648 3.75 3.5
    println(f"{quot(-2147483647 - 1, -1)} {shl(1, 33)}")      // DIV: -2147483648 2
    println(f"{bump(1073741824)} {bump(2.5)}")                // BUMP: 2147483647 -6
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=ADD,DIV,BUMP
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}dependent_run.k
// CXX: template<class T> T add(T a, T b) noexcept {
// CXX: auto && __kairo_a0 =(a);
// CXX-NEXT: auto && __kairo_b0 =(b);
// CXX: using __kairo_T0 = __remove_cvref(decltype(__kairo_a0));
// CXX-NEXT: if constexpr(__is_integral(__kairo_T0) &&(!__is_same(__kairo_T0, bool))) {
// CXX-NEXT: using __kairo_U0 = decltype(static_cast<__make_unsigned(__kairo_T0)>(0) + 0u);
// CXX-NEXT: return static_cast<__kairo_T0>(static_cast<__kairo_U0>(__kairo_a0) + static_cast<__kairo_U0>(__kairo_b0));
// CXX: return __kairo_a0 + __kairo_b0;
