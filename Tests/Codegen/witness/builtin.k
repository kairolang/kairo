// witness/builtin.k -- exit 8
// A builtin conformer has no members at all: always a specialization,
// spelled by the builtin's C++ type.
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
extend i32 {
    pub fn scale(const self, factor: i32) -> i32 = self * factor
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
fn main() -> i32 {
    var x: i32 = 4
    return twice(x)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/builtin.k
// CXX: template<> struct Scalable_witness<signed int> {
// CXX-NEXT: static signed int scale(const signed int * self, signed int factor) {
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_i32::scale(self,

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
