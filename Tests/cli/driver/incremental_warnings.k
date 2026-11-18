// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md#diagnostics):
// a reused TU still reports its warnings. Sema runs for every file every run,
// so Sema's come as always; codegen's own (SC241W here) come from the fill
// the key is hashed from, which runs for a reused TU too. Reported once per
// run, whether the TU compiled or was reused.

ffi "c" fn shl(x: u32, n: u32) -> u32 = x << n

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-armv7-linux-musl
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %t.d && { %kairo %s --freestanding --target thumbv7m-none-eabi -Wshift-count-unproven -c -o %t.d/a.o --cache-dir %t.d/c --print-stats > %t.d/one 2>&1 || true; }
// RUN: cd %t.d && { %kairo %s --freestanding --target thumbv7m-none-eabi -Wshift-count-unproven -c -o %t.d/b.o --cache-dir %t.d/c --print-stats > %t.d/two 2>&1 || true; }
// RUN: %FileCheck %s --input-file=%t.d/one
// RUN: %FileCheck %s --input-file=%t.d/two
// CHECK: incremental_warnings.k:7:41: warning [SC241W]
// CHECK-NOT: warning [SC241W]
// RUN: %FileCheck %s --input-file=%t.d/one --check-prefix=FIRST
// RUN: %FileCheck %s --input-file=%t.d/two --check-prefix=SECOND
// FIRST: [stats] incremental: 0 reused, 1 compiled, 1 stored
// SECOND: [stats] incremental: 1 reused, 0 compiled, 0 stored
// RUN: cmp %t.d/a.o %t.d/b.o
