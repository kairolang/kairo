// witness/own_member.k -- exit 6
// The same bound met by an OWN member: the primary serves the row, so no
// specialization is written (CODEGEN.md §7b.4), and the call still goes
// through the witness.
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub class Metric {
    pub var base: i32
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
// CXX-LABEL: CODEGEN C++: {{.*}}witness/own_member.k
// CXX: template<class __kairo_Self> struct Scalable_witness {
// CXX-NOT: template<> struct Scalable_witness
// CXX: Scalable_witness<T>::scale((& a), 2);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
