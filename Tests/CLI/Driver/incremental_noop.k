// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md): a
// rebuild with no source change against the same --cache-dir codegens no TU
// -- every object comes from the cache's store -- and links a binary byte
// for byte the same as the first build's. --print-stats reports the counts.

// --- lit wiring -----------------------------------------------------------
// Every incremental_*.k test compiles from its %t.d: lit's working directory
// is this one, a module root, and its Output/ beside output.k is a P002E case
// clash for any import resolved there.
// REQUIRES: default-sysroot, llvm-objdump
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a1 --cache-dir %t.d/c --print-stats 2>&1 | %FileCheck %s --check-prefix=FIRST
// FIRST: [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled, {{[1-9][0-9]*}} stored
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/c --print-stats 2>&1 | %FileCheck %s --check-prefix=SECOND
// SECOND: [stats] incremental: {{[1-9][0-9]*}} reused, 0 compiled, 0 stored
// RUN: cmp %t.d/a1 %t.d/a2
// RUN: %t.d/a2; test $? -eq 8
// --force-recompile skips the lookup; the next run reuses again.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a3 --cache-dir %t.d/c --force-recompile --print-stats 2>&1 | %FileCheck %s --check-prefix=FORCE
// FORCE: [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a4 --cache-dir %t.d/c --print-stats 2>&1 | %FileCheck %s --check-prefix=SECOND
// RUN: cmp %t.d/a1 %t.d/a3
//
// The record travels in the object, in a section the link drops: the
// objects have it, the binary does not, and it is the same binary a build
// without --cache-dir links.
// RUN: %objdump -h %t.d/c/main.o | %FileCheck %s --check-prefix=OBJ
// OBJ: .kairo.cache
// RUN: %objdump -h %t.d/a2 | %FileCheck %s --check-prefix=BIN
// BIN-NOT: .kairo.cache
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a0
// RUN: cmp %t.d/a0 %t.d/a2
