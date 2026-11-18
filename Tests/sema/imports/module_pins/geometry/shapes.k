// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
//
// `geo::shapes`: a file at the pinned library's top level.
//
// CHECK-NOT: error
//
// Compiled on its own (lit's cwd is this directory, the library's root) it is
// still `geo::shapes`, the module path every importer gives it: an input is a
// module like any import, and the cwd's
// own module.k pin names it. As an entry it is not `shapes` (a separately
// compiled importer's call to `geo::shapes::area` would not link).
// CXX: namespace geo::shapes {
// CXX-NOT: namespace shapes

pub fn area() -> i32 { return 4 }
