// witness/nested_modules/main.k -- exit 15
// The nested case across modules: `outer` (algo) calls `inner(Wrap<T>)`
// (shape), and only this TU names `outer<Metric>`. Its body is walked here,
// from algo's tree, to reach `inner<Wrap<Metric>>`, and that row's
// specialization is written in this TU, which homes the instance.
import algo
import metric::Metric
fn main() -> i32 {
    return algo::outer(Metric { base: 3 })
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}nested_modules/main.k
// CXX: template<> struct Scalable_witness<{{ ?}}::{{.*}}Wrap<{{ ?}}::{{.*}}::Metric>> {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
