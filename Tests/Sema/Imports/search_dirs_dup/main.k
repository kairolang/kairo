// RUN: { %kairo %s --type-check-only -I %S/Inputs 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %s --type-check-only -I %S/Inputs > /dev/null 2>&1
//
// IMPORTS.md §2.1: one module path from two search dirs is an error at the
// import. `a.k` sits beside this file (the cwd, which lit sets to this
// directory) and in `Inputs/` (an -I dir); both are module `a`, so `import a`
// names two files and one C++ namespace. Neither wins: which one did would
// depend on search order, and adding a file to an -I dir would silently
// change what an import elsewhere means. two_dirs.k is the same with no
// cwd copy, between two -I dirs.

import a

fn use_a() -> i32 { return a::which() }

// CHECK: main.k:12:{{[0-9]+}}: error [R017E]: ambiguous import 'a'
// CHECK-SAME: search_dirs_dup/a.k
// CHECK-SAME: search_dirs_dup/Inputs/a.k
