// witness/qualified.k -- exit 22
// The qualified form of a requirement call, `I::m(x, ...)`: `self` is the
// first argument, so Self is its type. On a bounded `T` it goes through the
// witness as `x.m()` does; on a CONCRETE conformer the call is its own
// instantiation site and carries its row, so Metric (an extension member)
// gets its specialization and Own (an own member) the primary.
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub class Own {
    pub var base: i32 = 2
    fn Own(self) { }
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub fn <T impl Scalable> viai(a: T) -> i32 {
    return Scalable::scale(a, 2)
}
fn main() -> i32 {
    var m = Metric { base: 1 }
    var o = Own()
    return viai(m) + Scalable::scale(m, 4) * 10 - 40 + Scalable::scale(o, 10)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/qualified.k
// CXX: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Metric> {
// CXX-NOT: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Own>
// CXX: Scalable_witness<T>::scale((& a), 2);
// CXX: Scalable_witness<{{ ?}}::{{.*}}::Metric>::scale((& m), 4)
// CXX-SAME: Scalable_witness<{{ ?}}::{{.*}}::Own>::scale((& o), 10)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
