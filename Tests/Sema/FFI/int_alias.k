// A typed integer argument that binds two imported overloads at Exact (C
// `int` and LLP64's 32-bit `long`, or LP64's `long` and `long long`) takes
// the C type the target spells that width with, as C++ does, instead of
// reporting an ambiguous call. `pick(long)` returns bool, so a wrong pick
// cannot pass for an i32.

ffi "c++" import "int_alias.h"

fn use(a: i32, b: i64) -> i64 {
    var p: i32 = pick(a)
    return wide(b) + (p as i64)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
