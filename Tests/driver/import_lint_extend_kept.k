// Scripts/import_lint.py --fix removes an import nothing resolved a name
// through, but keeps one whose target file holds `extend` blocks: such a
// file is used through no name, so the import edge is what compiles it.
// The fixed file is stable under a second --fix.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/import_lint_extend_run.py %kairo_bin %S/../../Scripts/import_lint.py %S/inputs/import_lint_extend | %FileCheck %s
// CHECK: FIRST 0
// CHECK: FIRST {{.*}}dead import 'import plain'
// CHECK: FIRST {{.*}}unused import kept: 'import ext'
// CHECK: FIRST {{.*}}written 3
// CHECK: SECOND 0
// CHECK: SECOND {{.*}}written 0
// CHECK: MAIN-BEGIN
// CHECK-NOT: import plain
// CHECK:     import ext;
// CHECK:     import shapes::circle::Circle;
