// witness/inherited.k -- exit 6
// The requirement is met by a member found on a BASE: still a member of the
// conformer to C++ (a member-pointer cast admits a base's member), so the
// primary serves the row and no specialization is written (CODEGEN.md
// §7b.3, §7b.4).
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub class Base {
    pub var base: i32 = 3
    fn Base(self) { }
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub class Derived derives Base {
    fn Derived(self) { }
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
fn main() -> i32 {
    var d = Derived()
    return twice(d)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/inherited.k
// CXX: template<class __kairo_Self> struct Scalable_witness {
// CXX-NOT: template<> struct Scalable_witness
// CXX: Scalable_witness<T>::scale((& a), 2);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
