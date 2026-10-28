// witness/generic_record.k -- exit 25
// A bounded RECORD, `class <T impl Scalable> Box`, and a bounded member
// template on it. The record's head carries NO concept -- not on its
// tier-0 forward declaration, its definition or an out-of-line member's
// owner head -- because clang checks a class template's constraints where
// the template-id is named, and a class names an instance over itself while
// still incomplete (oop/crtp_bounded.k, oop/bounded_self_field.k). The
// bound is pinned instead by a static_assert after the home's explicit
// instantiation. A member template's head keeps its own bound (a function's
// concept is in its mangled name). `Box<Metric>` is an instantiation site of
// its own: its row comes from the record instance, with no generic function
// involved (CODEGEN.md §7b.7, §7b.8).
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub class <T impl Scalable> Box {
    pub var item: T
    fn Box(self, item: T) { self.item = item; }
    pub fn twice(const self) -> i32 = self.item.scale(2)
    pub fn <U impl Scalable> both(const self, other: U) -> i32 = self.item.scale(1) + other.scale(10)
}
fn main() -> i32 {
    var b = Box<Metric>(Metric { base: 3 })
    return b.twice() + b.both(Metric { base: 1 }) + 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/generic_record.k
// CXX: template<class T> class Box;
// CXX: concept Scalable_c =
// CXX: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Metric> {
// CXX: template<class T> class Box {
// CXX: template<class U> requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<U>) signed int both(U other) const noexcept;
// CXX: template<class T> signed int Box<T>::twice() const noexcept {
// CXX-NEXT: {{.*}}Scalable_witness<T>::scale((& this->item), 2);
// CXX: template<class T> template<class U> requires{{ ?}}({{ ?}}::{{.*}}::Scalable_c<U>) signed int Box<T>::both(U other) const noexcept {
// CXX: template class{{ ?}}::{{.*}}::Box<{{ ?}}::{{.*}}::Metric>;
// CXX-NEXT: static_assert({{ ?}}::{{.*}}::Scalable_c<{{ ?}}::{{.*}}::Metric>, "Kairo checked this bound at the instance; C++ disagrees");

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 25
