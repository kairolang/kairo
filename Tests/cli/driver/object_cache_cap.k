// The object cache keeps at most 2 GB: after a run that stored, entries are
// evicted oldest-stored first down to 1.5 GB, never one this run fetched or
// stored and never one stored in the last hour. Without the bound every
// build of a changed tree stores a full new generation and the cache grows
// without limit.
//
// The store is seeded with sparse files (their size counts, their disk does
// not): two 1 GB entries a few days old and one stored now. A run that
// stores its own objects leaves the cache at about 3 GB, so the two old
// ones go, the recent one and the run's own entries stay. --cache-dir points
// at %t, so the test never touches a real cache.

pub fn first() -> i32 { return 1 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.c %t.d && mkdir -p %t.d
// RUN: printf 'pub fn second() -> i32 { return 2 }\n' > %t.d/second.k
// The first compile creates the store for this compiler and flags.
// RUN: %kairo %s -c -o %t.d/a.o --cache-dir %t.c
// RUN: O=$(echo %t.c/kairo-cache-v2/*/objects); test -d "$O"; echo "$O" > %t.d/objects
// RUN: ls "$(cat %t.d/objects)" | wc -l > %t.d/before
// RUN: python3 %S/inputs/library_cache_cap/seed.py file "$(cat %t.d/objects)"
// RUN: ls "$(cat %t.d/objects)" | grep -c '^fake' | grep -x 3 > /dev/null
// A different TU stores, which runs the sweep.
// RUN: %kairo %t.d/second.k -c -o %t.d/b.o --cache-dir %t.c
// RUN: test ! -e "$(cat %t.d/objects)"/fakeold-1-1.o
// RUN: test ! -e "$(cat %t.d/objects)"/fakeolder-1-1.o
// RUN: test -e "$(cat %t.d/objects)"/fakerecent-1-1.o
// The first run's entries all survive and this run's own was added.
// RUN: ls "$(cat %t.d/objects)" | grep -vc '^fake' > %t.d/after
// RUN: test "$(cat %t.d/after)" -gt "$(cat %t.d/before)"
// RUN: rm -rf %t.c %t.d
