// witness/generic_extension.k -- exit 2
// The witness is a GENERIC extension's member: `extend <E> Wrap<E>` meets
// Scalable for every Wrap. The row records the arguments the conformer
// binds the extension's parameters to (Wrap<i32>: E := i32), and the
// specialization calls `__kairo_ext_Wrap::scale<signed int>(...)` with them
// spelled, as any call to a generic extension member is.
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct <E> Wrap {
    pub var item: E
}
extend <E> Wrap<E> {
    pub fn scale(const self, factor: i32) -> i32 = factor + 100
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
fn main() -> i32 {
    return twice(Wrap<i32> { item: 5 }) - 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/generic_extension.k
// CXX: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Wrap<signed int>> {
// CXX-NEXT: static signed int scale(const{{ ?}}::{{.*}}::Wrap<signed int> * self, signed int factor) {
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_Wrap::scale<signed int>(self,

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
