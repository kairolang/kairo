// The entry TU's file stem is its C++ namespace, and `operator` is a C++
// keyword: `namespace operator { ... }` is eight clang errors. The stem of a
// keyword-named file gets a trailing `_` (CXXSpell::entry_stem). The name of
// this file IS the test; do not rename it.

fn one() -> i32 { return 1 }

fn main() -> i32 {
    return one() - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe
