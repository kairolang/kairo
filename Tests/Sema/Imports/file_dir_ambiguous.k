// `foo.k` beside `foo/module.k`: both are module `foo` in the one place
// `import self::foo` looks. The import is reported once, at the import,
// and resolves to the file so nothing cascades from it.
//
// Inputs/file_dir_ambiguous/app: main.k (imports self::foo), foo.k,
// foo/module.k.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/file_dir_ambiguous/app && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: main.k:1:1: error [R005E]: ambiguous module 'foo': both '{{.*}}app/foo.k' and '{{.*}}app/foo/module.k' are that module; rename or remove one
// CHECK-NOT: error
