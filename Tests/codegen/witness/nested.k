// witness/nested.k -- exit 27
// A generic calling a generic: `outer<T>` calls `inner(Wrap<T>{...})`, and
// `Holder<T>`'s method does too. `inner<Wrap<Metric>>` is never named in
// source; it is reached through `outer<Metric>`'s body and `Holder<Metric>`'s
// methods once T is known (CallTyping keeps the dependent call's deduced
// arguments, ConformanceChecking substitutes them per instance). Its row,
// `(Wrap<Metric>, Scalable)`, rides on the outer instances, so their TUs
// write its specialization; without it the concept rejects the call.
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub struct <E> Wrap {
    pub var item: E
}
extend <E> Wrap<E> {
    pub fn scale(const self, factor: i32) -> i32 = factor + 10
}
pub fn <U impl Scalable> inner(a: U) -> i32 {
    return a.scale(2)
}
pub fn <T impl Scalable> outer(a: T) -> i32 {
    return inner(Wrap<T> { item: a }) + a.scale(1)
}
pub class <T impl Scalable> Holder {
    pub var item: T
    fn Holder(self, item: T) { self.item = item; }
    pub fn go(const self) -> i32 = inner(Wrap<T> { item: self.item })
}
fn main() -> i32 {
    var h = Holder<Metric>(Metric { base: 3 })
    return outer(Metric { base: 3 }) + h.go()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/nested.k
// CXX-DAG: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Metric> {
// CXX-DAG: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Wrap<{{ ?}}::{{.*}}::Metric>> {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 27
