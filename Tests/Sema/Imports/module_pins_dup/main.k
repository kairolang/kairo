// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// IMPORTS.md §2.1: two pinned libraries in reach (liba/ and libb/, both
// immediate subdirectories of the cwd) declaring one name. A module path
// under that name would mean two files, so it is the same build error as two
// -I roots with one name: never first-wins, never a merge.

import dup

// CHECK: error [R018E]: duplicate module root 'dup'
// CHECK-SAME: liba
// CHECK-SAME: libb
// CHECK-SAME: module.k
