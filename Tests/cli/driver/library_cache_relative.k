// A relative KAIRO_CACHE_DIR names the same cache as its absolute
// spelling: the Kairo library a link builds under it is complete (not
// L007E) and the executable runs.
fn main() -> i32 { return 7 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d && mkdir -p %t.d/cache
// RUN: env KAIRO_CACHE_DIR=%t.d/objcache %kairo %s -c --emit-scope=inputs -o %t.d/main.o
// RUN: cd %t.d && env KAIRO_CACHE_DIR=cache %kairo %t.d/main.o --kairo-lib -o %t.exe
// RUN: %t.exe; test $? -eq 7
// RUN: test -d %t.d/cache/lib
// RUN: rm -rf %t.d
