// witness/static.k -- exit 8
// A STATIC requirement through a bound, `T::make()`: `static __kairo_Self
// make()` in the witness, called as `::N::Makeable_witness<T>::make()`
// (CODEGEN.md §7b.3, §7b.5). Its gate is a plain function pointer, and
// `-> Self` reads back as T through the `::` qualifier.
pub interface Makeable {
    static fn make() -> Self
    fn value(const self) -> i32
}
pub struct Seven {
    pub var v: i32
}
extend Seven {
    pub static fn make() -> Seven = Seven { v: 7 }
    pub fn value(const self) -> i32 = self.v
}
pub fn <T impl Makeable> build(seed: T) -> i32 {
    var t = T::make()
    return t.value() + seed.value()
}
fn main() -> i32 {
    return build(Seven { v: 1 })
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/static.k
// CXX: concept Makeable_c = requires(const __kairo_Self * __kairo_r1) {
// CXX-NEXT: Makeable_witness<__kairo_Self>::make();
// CXX: static __kairo_Self make() requires requires {
// CXX-NEXT: static_cast<__kairo_Self(*)()>(& __kairo_Self::make);
// CXX: return __kairo_Self::make();
// CXX: template<> struct Makeable_witness<{{ ?}}::{{.*}}::Seven> {
// CXX-NEXT: static{{ ?}}::{{.*}}::Seven make() {
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_Seven::make();
// CXX: T t = {{ ?}}::{{.*}}::Makeable_witness<T>::make();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
