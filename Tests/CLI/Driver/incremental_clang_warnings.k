// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md#diagnostics):
// a TU clang reports on is compiled but never stored -- the record does not
// carry clang's diagnostics (a phase-1 deviation) -- so it compiles, and its
// warning is reported, on every run, while the TUs clang said nothing about
// are reused. The C++ body below is a self-comparison clang warns on (C990W).

ffi "c" fn same(x: i32) -> bool = x == x

fn main() -> i32 { return if (same(1)) => (0) else => 1 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && %kairo %s -o %t.d/a --cache-dir %t.d/c --print-stats > %t.d/one 2>&1
// RUN: cd %t.d && %kairo %s -o %t.d/b --cache-dir %t.d/c --print-stats > %t.d/two 2>&1
// RUN: %FileCheck %s --input-file=%t.d/one
// RUN: %FileCheck %s --input-file=%t.d/two
// CHECK: incremental_clang_warnings.k:7:38: warning [C990W]
// CHECK-NOT: warning [C990W]
// RUN: %FileCheck %s --input-file=%t.d/one --check-prefix=FIRST
// RUN: %FileCheck %s --input-file=%t.d/two --check-prefix=SECOND
// FIRST: [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled
// SECOND: [stats] incremental: {{[1-9][0-9]*}} reused, 1 compiled, 0 stored
// RUN: cmp %t.d/a %t.d/b
// RUN: %t.d/b
