// What a runtime cache entry is keyed on: the exact cc1 line (here, the
// optimization level), and every file the runtime is built from -- a header
// in Lib/rt, and the vendored mimalloc, which rt/mimalloc.c only includes
// (a submodule bump never touches it). The runtime is a copy under %t,
// reached through --builtins-dir (the runtime root is its parent, after
// symlinks are resolved, so builtin is a copy too); not
// through %kairo, whose own --builtins-dir would win.

fn main() -> i32 { return 3 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.c %t.lib && mkdir -p %t.c %t.lib
// RUN: cp -RL %S/../../../Lib/builtin %t.lib/builtin
// RUN: cp -RL %S/../../../Lib/rt %t.lib/rt
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=MISS
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=HIT
// MISS:     runtime cache miss: {{.*}}/rt/mimalloc-
// MISS-NOT: runtime cache hit
// HIT:      runtime cache hit: {{.*}}/rt/mimalloc-
// HIT-NOT:  runtime cache miss

// Another optimization level is another cc1 line: its own entry, beside
// the first, which a link at the old level still hits.
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -O3 -v 2>&1 | %FileCheck %s --check-prefix=MISS
// RUN: %t.exe; test $? -eq 3
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -O3 -v 2>&1 | %FileCheck %s --check-prefix=HIT
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=HIT
// RUN: ls %t.c/rt | grep -c '^mimalloc-.*\.o$' | grep -qx 2

// A changed runtime header misses, and its store replaces the old entry of
// that slot rather than adding one.
// RUN: echo '/* edited */' >> %t.lib/rt/alloc.h
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=MISS
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=HIT
// RUN: ls %t.c/rt | grep -c '^mimalloc-.*\.o$' | grep -qx 2

// A changed mimalloc file (a submodule bump) misses too.
// RUN: echo '/* edited */' >> %t.lib/rt/mimalloc/include/mimalloc.h
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=MISS
// RUN: %t.exe; test $? -eq 3

// Under debug info the object records the working directory, so it is
// part of the key: the same -g link from another directory misses.
// RUN: rm -rf %t.d1 %t.d2 && mkdir -p %t.d1 %t.d2
// RUN: cd %t.d1 && env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -g -v 2>&1 | %FileCheck %s --check-prefix=MISS
// RUN: cd %t.d1 && env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -g -v 2>&1 | %FileCheck %s --check-prefix=HIT
// RUN: cd %t.d2 && env KAIRO_CACHE_DIR=%t.c %kairo_bin --error-format=basic --builtins-dir=%t.lib/builtin --std-dir=%S/../../../Lib/std %s -o %t.exe -g -v 2>&1 | %FileCheck %s --check-prefix=MISS
