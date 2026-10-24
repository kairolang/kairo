// witness/priv_iface.k -- exit 6
// A non-`pub` interface in an entry TU: its witness is emitted in the TU's
// namespace like any priv decl, and the instance still finds the row.
interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
struct Metric {
    var base: i32
}
extend Metric {
    fn scale(const self, factor: i32) -> i32 = self.base * factor
}
fn <T impl Scalable> twice(a: T) -> i32 {
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
// CXX-LABEL: CODEGEN C++: {{.*}}witness/priv_iface.k
// CXX: template<> struct Scalable_witness<{{ ?}}::{{.*}}::Metric> {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
