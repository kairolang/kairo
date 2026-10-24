// witness/extension.k -- exit 6
// The 2026-10-24 ticket: a `<T impl I>` body's call into the bound, where
// the conformance is an EXTENSION member. An extension member is a static
// of `__kairo_ext_Metric`, never a C++ member, so the call goes through the
// interface's witness and Metric's row is a specialization (CODEGEN.md §7b).
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
fn main() -> i32 {
    var m = Metric { base: 3 }
    return twice(m)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/extension.k
// The primary forwards to a member, gated on an exact member signature.
// CXX: template<class __kairo_Self> struct Scalable_witness;
// CXX: concept Scalable_c = requires(const __kairo_Self * __kairo_r0, signed int __kairo_a0) {
// CXX-NEXT: Scalable_witness<__kairo_Self>::scale(__kairo_r0, __kairo_a0);
// CXX: template<class __kairo_Self> struct Scalable_witness {
// CXX-NEXT: static signed int scale(const __kairo_Self * self, signed int factor) requires requires {
// CXX-NEXT: static_cast<signed int(__kairo_Self::*)(signed int) const>(& __kairo_Self::scale);
// CXX: return self->scale(static_cast<decltype(factor) &&>(factor));
// Metric's row: after the scope it forwards to.
// CXX: struct __kairo_ext_Metric {
// CXX: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Metric> {
// CXX-NEXT: static signed int scale(const{{ ?}}::{{.*}}::Metric * self, signed int factor) {
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_Metric::scale(self, static_cast<decltype(factor) &&>(factor));
// The bound renders as the concept, declaration and body alike.
// CXX: template<class T> requires{{ ?}}::{{.*}}::Scalable_c<T> signed int twice(T a);
// CXX: template<class T> requires{{ ?}}::{{.*}}::Scalable_c<T> signed int twice(T a) {
// CXX-NEXT: return{{ ?}}::{{.*}}::Scalable_witness<T>::scale((& a), 2);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
