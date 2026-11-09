// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md#global-invalidation):
// an option that can change an object is in the toolchain fingerprint F, and
// changing it recompiles every TU; one that changes only what is printed (-A,
// a Kairo-only -W) or only the link (--rpath, -l) recompiles nothing.
//
// Deviation, phase 1: clang's own -W words (-Wall here) are in every key too.
// The record does not carry clang's diagnostics, so an object is reusable only
// under the warning set it was compiled with. A change of compiler version is
// covered by F as well but cannot be exercised with one compiler binary; the
// notes record that check.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a0 --cache-dir %t.d/c
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c --print-stats -A R058W -W R062W 2>&1 | %FileCheck %s --check-prefix=NONE
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/c --print-stats --rpath=%t.d/nowhere -lm 2>&1 | %FileCheck %s --check-prefix=NONE
// NONE: [stats] incremental: {{[1-9][0-9]*}} reused, 0 compiled, 0 stored
// RUN: cmp %t.d/a0 %t.d/a1
//
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/o1 --cache-dir %t.d/c --print-stats -O1 2>&1 | %FileCheck %s --check-prefix=ALL
// ALL: [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled
// The -O1 objects are kept beside the -O0 ones (another F): both reuse.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/o1b --cache-dir %t.d/c --print-stats -O1 2>&1 | %FileCheck %s --check-prefix=NONE
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a3 --cache-dir %t.d/c --print-stats 2>&1 | %FileCheck %s --check-prefix=NONE
// RUN: cmp %t.d/a0 %t.d/a3
//
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/w --cache-dir %t.d/c --print-stats -Wall 2>&1 | %FileCheck %s --check-prefix=ALL
