// A write that fails partway leaves no partial project: --init removes the
// files and directories it already wrote, names the file it could not write,
// and exits nonzero. include/ exists but cannot be written to, so
// source/main.k (written first) is removed again, with source/.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: dir-permissions
// RUN: chmod -R u+w %t 2>/dev/null || true
// RUN: rm -rf %t && mkdir -p %t/part/include
// RUN: chmod 555 %t/part/include
// RUN: { not %kairo --init %t/part 2>&1; } | %FileCheck %s
// CHECK-NOT: created
// CHECK: error [U001E]: --init: cannot write '{{.*}}part/include/module.k'; nothing was written
// RUN: test ! -e %t/part/source
// RUN: test ! -e %t/part/Makefile
// RUN: test -d %t/part/include
// RUN: chmod 755 %t/part/include
