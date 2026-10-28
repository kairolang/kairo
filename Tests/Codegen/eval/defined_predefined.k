// `defined!` asks Kairo's macro table first (a `macro`, a `-D`), and for
// any other name clang's predefined macros for the target (EVAL.md §4.3):
// this file has no ffi header, so `__x86_64__` / `__aarch64__` come from
// the target's predefines alone. It is a bool (was the integer 1 / 0), so
// it is a condition anywhere, and an `eval if` on it is folded: the
// untaken branch names nothing that exists.
macro MINE! { 1 }

eval if defined!(__x86_64__) || defined!(__aarch64__) || defined!(__riscv) {
    fn arch() -> i32 { return 1 }
} else {
    fn arch() -> i32 { return no_such_arch() }
}

eval if defined!(__KAIRO_NOT_A_MACRO__) || (!defined!(MINE)) {
    fn k() -> i32 { return nope() }
} else {
    fn k() -> i32 { return 2 }
}

fn main() -> i32 {
    var on_cmd_line = defined!(EVAL_TEST_FLAG)          // -D in the second run
    var r = arch() + k()
    if on_cmd_line { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
// RUN: %kairo %s -DEVAL_TEST_FLAG -o %t2.exe --cache-dir %t.e
// RUN: %t2.exe; test $? -eq 7
