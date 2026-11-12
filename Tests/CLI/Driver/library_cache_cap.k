// The runtime cache and the Kairo library cache keep at most 2 GB each, as
// the object cache does. Past the cap a store
// evicts the oldest entries down to 1.5 GB, never one this run fetched or
// stored and never one stored in the last hour. Before, both had only the
// 30-day age bound and grew without limit.
//
// Each cache is seeded with sparse files (their size counts, their disk
// does not): two 1 GB entries a few days old and one stored now. The run
// stores its own entries, so the cache holds about 3 GB: the two old ones
// go (oldest first, until at most 1.5 GB is left), the recent one and the
// run's own entries stay. KAIRO_CACHE_DIR points at %t, so the test never
// touches a real cache.

fn main() -> i32 { return 7 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.c %t.d && mkdir -p %t.c/rt %t.c/lib %t.d

// Runtime cache: the cold link stores every runtime object.
// RUN: python3 %S/Inputs/library_cache_cap/seed.py file %t.c/rt
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -o %t.exe -v 2>&1 | %FileCheck %s --check-prefix=COLD
// COLD: runtime cache miss: {{.*}}/rt/mimalloc-
// RUN: %t.exe; test $? -eq 7
// RUN: test ! -e %t.c/rt/fakeold-1-1.o
// RUN: test ! -e %t.c/rt/fakeolder-1-1.o
// RUN: test -e %t.c/rt/fakerecent-1-1.o
// RUN: ls %t.c/rt | grep -c '^mimalloc-.*\.o$' | grep -qx 1

// Library cache: a link of separately compiled objects builds the library.
// RUN: python3 %S/Inputs/library_cache_cap/seed.py tree %t.c/lib
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -c --emit-scope=inputs -o %t.d/main.o
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %t.d/main.o --kairo-lib -o %t.d/lib.exe
// RUN: %t.d/lib.exe; test $? -eq 7
// RUN: test ! -e %t.c/lib/fakeold-1
// RUN: test ! -e %t.c/lib/fakeolder-1
// RUN: test -e %t.c/lib/fakerecent-1
// RUN: ls %t.c/lib | grep -v '^fake' | grep -c . | grep -qx 1
// RUN: rm -rf %t.c %t.d
