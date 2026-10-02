// crossfile/main.k -- exit 46
import point::Point;
import shape
import drawable::*;

fn main() -> i32 {
    var p = Point { x: 3, y: 4 };
    var q = shape::Point { a: 2, b: 3 };
    return p.sum() + p.draw() + q.draw();
}

// --- lit wiring -----------------------------------------------------------
// Four TUs. drawable's `impl` extends get their OWN scopes in its own
// namespace and are not friends. Neither target is declared in drawable, so
// each scope is named by its target's full path: two `Point`s, two structs.
// point's Point befriends only point's scope, so its definition is the same
// text in every TU and names nothing from drawable. point's scope is defined
// whole in main, priv `peek` included, so main declares the Box it names.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: CODEGEN C++: {{.*}}crossfile/drawable.k
// CXX-DAG: struct __kairo_ext_point__Point {
// CXX-DAG: struct __kairo_ext_shape__Point {
// CXX-DAG: signed int __kairo_ext_point__Point::draw(const::point::Point * self) {
// CXX-DAG: signed int __kairo_ext_shape__Point::draw(const::shape::Point * self) {
// CXX: CODEGEN C++: {{.*}}crossfile/point.k
// CXX-NOT: drawable
// CXX: friend struct::point::__kairo_ext_Point;
// CXX-NOT: drawable
// CXX: CODEGEN C++: {{.*}}crossfile/main.k
// CXX: class Box {
// CXX: struct __kairo_ext_Point {
// CXX: peek(const::point::Point * self, ::point::Box::Inner i);
// CXX: ::point::__kairo_ext_Point::sum((& p))
// CXX-SAME: ::drawable::__kairo_ext_point__Point::draw((& p))
// CXX-SAME: ::drawable::__kairo_ext_shape__Point::draw((& q))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 46
