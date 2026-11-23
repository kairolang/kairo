// The CPU a build targets is part of every cache key
// (Compiler/Spec/Incremental.md#global-invalidation): against one
// --cache-dir and one runtime cache, a build for x86-64-v3 and a build for
// the baseline CPU reuse nothing of each other's, neither the program's
// objects nor the runtime's, and each reuses all of its own. The proof that
// nothing crossed over is in the program: built for the baseline after the
// x86-64-v3 build filled both caches, it holds no AVX instruction, where
// the x86-64-v3 one does. The host CPU default changes the key the same
// way, since it is written into the same cc1 words.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot, host-x86_64, llvm-objdump
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/inputs/incremental %t.d/s
// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/k %kairo -I %t.d/s %t.d/s/main.k -O2 -o %t.d/v3 --cache-dir %t.d/c --march=x86-64-v3 -v --print-stats > %t.d/v3.log 2>&1
// RUN: %FileCheck %s --check-prefix=COLD < %t.d/v3.log
// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/k %kairo -I %t.d/s %t.d/s/main.k -O2 -o %t.d/base --cache-dir %t.d/c -v --print-stats > %t.d/base.log 2>&1
// RUN: %FileCheck %s --check-prefix=COLD < %t.d/base.log
// COLD-NOT: runtime cache hit
// COLD:     runtime cache miss: {{.*}}/rt/mimalloc-
// COLD-NOT: runtime cache hit
// COLD:     [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled

// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/k %kairo -I %t.d/s %t.d/s/main.k -O2 -o %t.d/v3b --cache-dir %t.d/c --march=x86-64-v3 -v --print-stats > %t.d/v3b.log 2>&1
// RUN: %FileCheck %s --check-prefix=WARM < %t.d/v3b.log
// RUN: cd %t.d && env KAIRO_CACHE_DIR=%t.d/k %kairo -I %t.d/s %t.d/s/main.k -O2 -o %t.d/baseb --cache-dir %t.d/c -v --print-stats > %t.d/baseb.log 2>&1
// RUN: %FileCheck %s --check-prefix=WARM < %t.d/baseb.log
// WARM-NOT: runtime cache miss
// WARM:     runtime cache hit: {{.*}}/rt/mimalloc-
// WARM-NOT: runtime cache miss
// WARM:     [stats] incremental: {{[1-9][0-9]*}} reused, 0 compiled, 0 stored
// RUN: cmp %t.d/v3 %t.d/v3b
// RUN: cmp %t.d/base %t.d/baseb

// RUN: %t.d/base; test $? -eq 8
// RUN: %objdump -d --no-show-raw-insn %t.d/base > %t.d/base.s
// RUN: %objdump -d --no-show-raw-insn %t.d/v3 > %t.d/v3.s
// RUN: grep -q -e '%ymm' -e 'ymm[0-9]' %t.d/v3.s
// RUN: not grep -e 'ymm[0-9]' -e 'zmm[0-9]' -e 'vfmadd' %t.d/base.s
