// main.k's rule for INPUTS (decision E). Every input is a module now
// (decision C), so `a.k` (the cwd's) and `Inputs/a.k` (under `-I Inputs`)
// given together are both module `a`: one C++ namespace, and one object
// path, `a.o`, the second written over the first. Nothing imports either,
// so the import-time R017E never ran, and the run exited 0 with one
// module's code silently gone. The driver claims every input's module path
// before compiling any.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %S/a.k %S/Inputs/a.k -I %S/Inputs -c --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %S/a.k %S/Inputs/a.k -I %S/Inputs --type-check-only > /dev/null 2>&1
// CHECK: error [R018E]: '{{.*}}search_dirs_dup/a.k' and '{{.*}}search_dirs_dup/Inputs/a.k' are both module 'a'
// Rejected before either is compiled: no object was written.
// RUN: test ! -e %t.d/a.o
