// A `.copy-` tree is what a Windows library publish leaves when it is
// interrupted between the copy and the rename. The library cache removes
// one a day old, and counts the rest inside its 2 GB cap like any library:
// past the cap the oldest go first, down to 1.5 GB, never one stored in the
// last hour.
//
// The cache is seeded with four leftover trees (inputs/.../seed.py): 3 GB
// three hours old, 1 MB two hours old, 1 GB stored now and 1 MB two days
// old. The link builds a library, which runs the cache's cleanup: the
// two-day-old tree goes by age, the 3 GB one by size, and the other two
// stay. KAIRO_CACHE_DIR points at %t, so the test never touches a real
// cache.

fn main() -> i32 {
    return 7
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.c %t.d && mkdir -p %t.c/lib %t.d
// RUN: python3 %S/inputs/library_cache_copy_leftover/seed.py %t.c/lib
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %s -c --emit-scope=inputs -o %t.d/main.o
// RUN: env KAIRO_CACHE_DIR=%t.c %kairo %t.d/main.o --kairo-lib -o %t.d/lib.exe
// RUN: %t.d/lib.exe; test $? -eq 7
// RUN: test ! -e %t.c/lib/lib-1.copy-904
// RUN: test ! -e %t.c/lib/lib-1.copy-901
// RUN: test -e %t.c/lib/lib-1.copy-902
// RUN: test -e %t.c/lib/lib-1.copy-903
// RUN: ls %t.c/lib | grep -v 'copy-' | grep -c . | grep -x 1 > /dev/null
// RUN: rm -rf %t.c %t.d
