// A brace initializer names a default-`priv` field (a class variable is
// private unless marked) only in the file that declares the class.
// inputs/access_init_other_file/main.k initializes `C { y: 10 }` from
// another file: SC242E at `y` (line 4) with the `pub` fix-it into lib.k.
// lib.k's own `C { y: 10 }` is clean.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/inputs/access_init_other_file && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// RUN: cd %S/inputs/access_init_other_file && { %kairo lib.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OWN --allow-empty
// CHECK: main.k:4:{{[0-9]+}}: error [SC242E]: field 'y' of 'C' is private
// CHECK-NEXT: fix-it:"{{.*}}lib.k":{1:15-1:15}:"pub "
// CHECK-NEXT: lib.k:1:{{[0-9]+}}: note [SC242N]: 'y' is private by default
// OWN-NOT: error
