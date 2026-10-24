// witness/compound.k -- exit 75
// Compound assignment on a bounded `T` binds through the bound, as a binary
// operator does: `acc += b` derived from the bound's `op +` is
// `acc = I_witness<T>::__kairo_op_plus(acc, b)`, and a declared `op +=` is
// called through the witness as it is.
pub interface Addable {
    fn op +(const self, other: Self) -> Self
}
pub interface Growable {
    fn op +=(self, by: i32)
}
pub struct V {
    pub var v: i32
}
extend V {
    pub fn op +(const self, other: V) -> V = V { v: self.v + other.v }
}
pub struct W {
    pub var v: i32
}
extend W {
    pub fn op +=(self, by: i32) { self.v += by; }
}
pub fn <T impl Addable> sum3(a: T, b: T) -> T {
    var acc = a
    acc += b
    acc += b
    return acc
}
pub fn <T impl Growable> grow(a: T) -> T {
    var x = a
    x += 4
    return x
}
fn main() -> i32 {
    return sum3(V { v: 1 }, V { v: 2 }).v + grow(W { v: 3 }).v * 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/compound.k
// CXX: (acc ={{ ?}}::{{.*}}::Addable_witness<T>::__kairo_op_plus(acc, b));
// CXX: Growable_witness<T>::__kairo_op_plus_eq(x, 4);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 75
