// RUN: { %kairo %s --type-check-only -I %S/Inputs/inc 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-cxx -I %S/Inputs/inc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
//
// IMPORTS.md §2.1: `-I dir` is an UNNAMED search directory, like the cwd. A
// file under it, and under no pinned library, is its path relative to that
// directory: `Inputs/inc/util.k` is `util` and `Inputs/inc/sub/deep.k` is
// `sub::deep`. The folder's own name (`inc`) is no part of either -- it used
// to be, which made three `-I .../include` dirs collide (see f20.k).

import util
import sub::deep

fn use_both() -> i32 {
    return util::util_value() + deep::depth()
}

// DIAG-NOT: error

// CXX-DAG: namespace util {
// CXX-DAG: namespace sub::deep {
// CXX-NOT: namespace inc
