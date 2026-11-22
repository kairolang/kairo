// A declared `impl` is checked against what its own file sees. In
// inputs/impl_declared_other_file, point.k declares `class Point impl
// Shape` but Point's `name` is an extension in point_name.k, which point.k
// does not import: the conformance does not hold where it is declared, so
// it is an error at point.k's clause even though main.k, which imports
// both, could use it. dot_shape.k's `extend Dot impl Shape` is met by Dot's
// own `area` and by the `name` of dot_name.k, which dot_shape.k imports:
// clean.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/inputs/impl_declared_other_file && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// RUN: cd %S/inputs/impl_declared_other_file && { %kairo dot_shape.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DOT --allow-empty
// CHECK: point.k:2:22: error [SC162E]: 'Point' declares 'impl Shape' but does not conform to it: it has no 'name' with the requirement's signature
// CHECK: shape.k:3:5: note [I900N]: 'name' is required here
// DOT-NOT: error
