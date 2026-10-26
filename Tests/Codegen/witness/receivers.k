// witness/receivers.k -- exit 15
// Two bounds on two parameters, each call through its own witness; a
// non-const receiver (`[S]*`), and a PRVALUE receiver, which takes the
// materialized temporary an extension member's does (ExtensionLowering,
// `__kairo_tmp`), alive to the end of the full-expression.
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub interface Bumpable {
    fn bump(self)
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
    pub fn bump(self) { self.base += 1; }
}
pub fn <T impl Scalable, U impl Bumpable> both(a: T, b: U) -> i32 {
    var c = b
    c.bump()
    return a.scale(2)
}
fn <T> same(a: T) -> T = a
pub fn <T impl Scalable> viatmp(a: T) -> i32 {
    return same(a).scale(3)
}
fn main() -> i32 {
    var m = Metric { base: 3 }
    var n = Metric { base: 1 }
    return both(m, n) + viatmp(m)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/receivers.k
// CXX: static void bump(__kairo_Self * self) requires requires {
// CXX: requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<T> && {{ ?}}::{{.*}}::Bumpable_c<U>) signed int both(T a, U b) noexcept;
// CXX: Bumpable_witness<U>::bump((& c));
// CXX: Scalable_witness<T>::scale((& a), 2);
// CXX: Scalable_witness<T>::scale({{ ?}}::__kairo_tmp({{.*}}::same(a)), 3);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
