// The runtime's C objects (Lib/rt, mimalloc among them) are cached under
// the toolchain's cache root, so a link compiles them once, not every time:
// the first link misses and stores, the second takes every object from the
// cache and the program still runs, and --force-recompile skips the lookup
// but leaves one entry per object (the store replaces its own slot).
// KAIRO_CACHE_DIR points at %t, so the test never touches a real cache.

fn main() -> i32 { return 7 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.c && mkdir -p %t.c
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=COLD
// COLD:     runtime cache miss: {{.*}}.tmp.c/rt/mimalloc-{{[0-9A-F]+}}-{{[0-9A-F]+}}.o
// COLD-NOT: runtime cache hit
// RUN: %t.exe; test $? -eq 7
// RUN: ls %t.c/rt | grep -c '^mimalloc-.*\.o$' | grep -qx 1
// RUN: test -z "$(ls %t.c/rt | grep tmp-)"

// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=WARM
// WARM:     runtime cache hit: {{.*}}.tmp.c/rt/crash-{{[0-9A-F]+}}-{{[0-9A-F]+}}.o
// WARM:     runtime cache hit: {{.*}}.tmp.c/rt/mimalloc-{{[0-9A-F]+}}-{{[0-9A-F]+}}.o
// WARM-NOT: runtime cache miss
// RUN: %t.exe; test $? -eq 7

// The working directory is not part of the key without debug info: a link
// from elsewhere hits the same entries.
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d && env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=WARM

// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v --force-recompile 2>&1 | %FileCheck %s --check-prefix=FORCE
// FORCE:     runtime cache bypassed (--force-recompile): {{.*}}/rt/mimalloc-
// FORCE-NOT: runtime cache hit
// RUN: %t.exe; test $? -eq 7
// RUN: ls %t.c/rt | grep -c '^mimalloc-.*\.o$' | grep -qx 1

// A damaged entry is rebuilt, not linked: every entry truncated to a few
// bytes reads as no object and misses.
// RUN: for f in %t.c/rt/*.o; do printf 'junk' > "$f"; done
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=CORRUPT
// CORRUPT:     runtime cache miss: {{.*}}/rt/mimalloc-
// CORRUPT-NOT: runtime cache hit
// RUN: %t.exe; test $? -eq 7
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=WARM
