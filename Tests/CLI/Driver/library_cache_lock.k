// Links that all miss one empty Kairo library cache each build the library
// and publish it under `<entry>.lock`, one at a time: the later ones find
// the first's library in their check and use it, so none moves a fresh
// library aside under another's read of it (L007E), and none leaves its
// lock behind. Inputs/library_cache_lock/race.py starts the links at once.
// A lock a crashed link left is taken over once it is older than the bound
// (the unit test AtomicFile in Tests/Unit covers that rule).
fn main() -> i32 { return 7 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.c %t.d && mkdir -p %t.d
// RUN: env KAIRO_CACHE_DIR=%t.d/objcache %kairo %s -c --emit-scope=inputs -o %t.d/main.o
// RUN: python3 %S/Inputs/library_cache_lock/race.py --links 4 --rounds 1 --cache %t.c --obj %t.d/main.o --out %t.d -- %kairo | %FileCheck %s
// CHECK: round 0: ok, 4 links
// RUN: rm -rf %t.c %t.d
