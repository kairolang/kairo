// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md): a
// body-only edit to a non-generic, non-inline function changes only its own
// file's stream, so only that file's object is regenerated, and the binary
// is byte-identical to a clean build of the edited tree. Once with the
// interface PCH off (this graph's default size) and once forced on, where the
// PCH is still built over every TU, the reused ones included, as a clean
// build builds it.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/p1 --cache-dir %t.d/pc --interface-pch=on
// RUN: sed -e 's/x \* 3/x * 4/' %t.d/s/util.k > %t.d/u && mv %t.d/u %t.d/s/util.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/c --print-stats -v 2>&1 | %FileCheck %s
// CHECK-NOT: incremental: compiling main
// CHECK: incremental: compiling util (changed: stream)
// CHECK-NOT: incremental: compiling
// CHECK: [stats] incremental: {{[1-9][0-9]*}} reused, 1 compiled, 1 stored
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/clean --cache-dir %t.d/fresh
// RUN: cmp %t.d/a2 %t.d/clean
// RUN: %t.d/a2; test $? -eq 9
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/p2 --cache-dir %t.d/pc --interface-pch=on --print-stats 2>&1 | %FileCheck %s --check-prefix=PCH
// PCH: [stats] incremental: {{[1-9][0-9]*}} reused, 1 compiled, 1 stored
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/pclean --cache-dir %t.d/pfresh --interface-pch=on
// RUN: cmp %t.d/p2 %t.d/pclean
