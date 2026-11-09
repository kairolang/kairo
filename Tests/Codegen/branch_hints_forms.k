// in more positions: a hint inside an `else`, on a nested `if`, and
// `__builtin_expect` as a loop condition each put branch_weights on their
// own branch at -O2, and the hint does not change the program's result.

ffi "c" fn ext_a(x: i32) -> i32
ffi "c" fn ext_b(x: i32) -> i32

fn chain(x: i32) -> i32 {
    if x > 100 { return ext_a(1) }
    else { @unlikely if x > 50 { return ext_b(2) } }
    return ext_a(3)
}
fn nested(x: i32) -> i32 {
    if x > 0 {
        @likely if x < 1000 { return ext_a(x) }
    }
    return ext_b(x)
}
fn spin(n: i32) -> i32 {
    var i = 0
    while __builtin_expect(i < n, true) { i += ext_a(i) }
    return i
}

fn main() -> i32 { return chain(1) + nested(2) + spin(3) }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d
// RUN: %FileCheck %s < %t.d/branch_hints_forms.ll
// CHECK-LABEL: define {{.*}}@_ZN18branch_hints_forms5chainEi(
// CHECK:       !prof
// CHECK-LABEL: define {{.*}}@_ZN18branch_hints_forms6nestedEi(
// CHECK:       !prof
// CHECK-LABEL: define {{.*}}@_ZN18branch_hints_forms4spinEi(
// CHECK:       !prof
