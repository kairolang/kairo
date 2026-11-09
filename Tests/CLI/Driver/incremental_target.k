// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md#global-invalidation):
// the target is part of the toolchain fingerprint, so another target's build
// against the same --cache-dir reuses nothing, and each target's objects are
// kept apart and reused by that target's next build.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a0 --cache-dir %t.d/c
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/m0 --cache-dir %t.d/c --target=x86_64-linux-musl --print-stats 2>&1 | %FileCheck %s --check-prefix=ALL
// ALL: [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/m1 --cache-dir %t.d/c --target=x86_64-linux-musl --print-stats 2>&1 | %FileCheck %s --check-prefix=NONE
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c --print-stats 2>&1 | %FileCheck %s --check-prefix=NONE
// NONE: [stats] incremental: {{[1-9][0-9]*}} reused, 0 compiled, 0 stored
// RUN: cmp %t.d/a0 %t.d/a1
// RUN: cmp %t.d/m0 %t.d/m1
