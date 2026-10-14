// --diag-absolute-paths prints the absolute path of the file in a
// diagnostic. Run from the test's own directory with a bare file name so a
// relative path would show.
fn main() -> i32 { var a: i32 = u1; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S && { %kairo diag_absolute_paths.k --type-check-only --diag-absolute-paths 2>&1 || true; } | %FileCheck %s
// CHECK: {{^}}/{{.*}}diag_absolute_paths.k:{{[0-9]+}}:{{[0-9]+}}: error [R020E]: use of undeclared identifier 'u1'
