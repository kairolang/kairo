// A generic value parameter is `eval N: T` (EVAL.md 3: its value is a
// compile-time constant). The old `const N: T` is an error with a fix-it
// rewriting `const` to `eval`, and still parses as the same parameter, so
// nothing after it cascades.
class <eval N: usize> Buf { }
fn <T, eval K: i32> pick(x: T) -> T { return x }
class <const M: usize> Old { }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: generic_value_param.k:7:8: error [S001E]: a generic value parameter is written 'eval N: T', not 'const N: T'; its value is a compile-time constant
// DIAG-NEXT: fix-it:{{.*}}:{7:8-7:13}:"eval"

// RUN: { %kairo %s --type-check-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=SRC
// SRC: class<eval N: usize> Buf {}
// SRC: fn<T, eval K: i32> pick(
// SRC: class<eval M: usize> Old {}
