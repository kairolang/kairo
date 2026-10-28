// `defined!` of a macro an ffi header #defines (EVAL.md §4.3): the TU's
// HeaderSet keeps clang's preprocessor alive, so the folded `eval if` sees
// KAIRO_EVAL_TEST_FEATURE (and the target's `__linux__`-style predefines,
// which that preprocessor holds too).
ffi "c" import "feature.h"

eval if defined!(KAIRO_EVAL_TEST_FEATURE) {
    fn value() -> i32 { return c_value() }
} else {
    fn value() -> i32 { return not_declared_anywhere() }
}

eval if defined!(KAIRO_EVAL_TEST_ABSENT) {
    fn extra() -> i32 { return also_missing() }
} else {
    fn extra() -> i32 { return 2 }
}

fn main() -> i32 { return value() + extra() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
