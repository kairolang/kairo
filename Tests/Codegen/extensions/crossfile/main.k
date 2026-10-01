// crossfile/main.k -- exit 41
import point::Point;
import drawable::*;

fn main() -> i32 {
    var p = Point { x: 3, y: 4 };
    return p.sum() + p.draw();
}

// --- lit wiring -----------------------------------------------------------
// Three TUs. drawable's `impl` extend gets its OWN scope in its own namespace
// and is not a friend; point's Point befriends only point's scope, so its
// definition is the same text in every TU and names nothing from drawable.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: CODEGEN C++: {{.*}}crossfile/drawable.k
// CXX: namespace drawable {
// CXX: struct __kairo_ext_Point {
// CXX: signed int __kairo_ext_Point::draw(const::point::Point * self) {
// CXX: CODEGEN C++: {{.*}}crossfile/point.k
// CXX-NOT: drawable
// CXX: friend struct::point::__kairo_ext_Point;
// CXX-NOT: drawable
// CXX: CODEGEN C++: {{.*}}crossfile/main.k
// CXX: ::point::__kairo_ext_Point::sum((& p))
// CXX-SAME: ::drawable::__kairo_ext_Point::draw((& p))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 41
