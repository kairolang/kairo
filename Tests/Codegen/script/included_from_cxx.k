// A `.k` file that a C++ input includes, and that the command line does
// not name, is a module of the C++ program, not where the program starts:
// its top-level statement is the module error, in every mode.

fn unused() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo -I %S/Inputs/included %S/Inputs/included/main.cc -o %t.d/app --cache-dir %t.d/obj 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo -I %S/Inputs/included --type-check-only %S/Inputs/included/main.cc 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:      geo.k:8:1: error [SC001E]: a top-level statement runs only in the program's root file; this file is imported as a module
// DIAG-NEXT: geo.k:8:1: note [SC001N]: move it into a function, or into the file the program starts from
// DIAG-NOT: {{error|warning}}
