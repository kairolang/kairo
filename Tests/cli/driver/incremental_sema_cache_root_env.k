// Incremental Sema (Compiler/Spec/IncrementalSema.md#phase-2): the variables
// of the cache-root chain are keyed. With no KAIRO_SYSROOT_CACHE and no
// KAIRO_CACHE_DIR, HOME (or XDG_CACHE_HOME ahead of it) picks the cached
// sysroot of a target that ships none, and so its headers. Two homes whose
// cached roots differ in one header: the run under the second home must
// not be a hit replaying the first one's clean verdict, it must find the
// header missing. Before the fix f.env did not cover HOME, and the second
// run was "hit" with no error.

ffi "c" import "kprobe.h"

fn main() -> i32 {
    return kprobe()
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell, host-linux, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d && mkdir -p %t.d/h1/.cache/kairo/sysroot/by-name %t.d/h2/.cache/kairo/sysroot/by-name %t.d/x/kairo/sysroot/by-name
// RUN: cp -rs "$(dirname "$(dirname %kairo_bin)")/sysroot/x86_64-linux-musl" %t.d/fake
// RUN: echo 'static inline int kprobe(void) { return 0; }' > %t.d/fake/include/kprobe.h
// RUN: ln -s %t.d/fake %t.d/h1/.cache/kairo/sysroot/by-name/powerpc64le-linux-musl
// RUN: ln -s "$(dirname "$(dirname %kairo_bin)")/sysroot/x86_64-linux-musl" %t.d/h2/.cache/kairo/sysroot/by-name/powerpc64le-linux-musl
// RUN: ln -s %t.d/fake %t.d/x/kairo/sysroot/by-name/powerpc64le-linux-musl
// RUN: cp %s %t.d/main.k
//
// The first home: the header is there, a record, then a hit.
// RUN: cd %t.d && env -u KAIRO_CACHE_DIR -u KAIRO_SYSROOT_CACHE -u XDG_CACHE_HOME -u LOCALAPPDATA HOME=%t.d/h1 %kairo main.k --target=powerpc64le-linux-musl --no-sysroot-build --type-check-only --cache-dir c --incremental-sema --print-incr-status > o1 2>&1
// RUN: cd %t.d && env -u KAIRO_CACHE_DIR -u KAIRO_SYSROOT_CACHE -u XDG_CACHE_HOME -u LOCALAPPDATA HOME=%t.d/h1 %kairo main.k --target=powerpc64le-linux-musl --no-sysroot-build --type-check-only --cache-dir c --incremental-sema --print-incr-status > o2 2>&1
// RUN: %FileCheck %s --check-prefix=MISS0 --input-file=%t.d/o1
// RUN: %FileCheck %s --check-prefix=HIT --input-file=%t.d/o2
// MISS0: incremental: miss: no record
// MISS0-NOT: error
// HIT: incremental: hit, {{[1-9][0-9]*}} modules
// HIT-NOT: error
//
// The second home: a miss, and the header is not found.
// RUN: cd %t.d && { env -u KAIRO_CACHE_DIR -u KAIRO_SYSROOT_CACHE -u XDG_CACHE_HOME -u LOCALAPPDATA HOME=%t.d/h2 %kairo main.k --target=powerpc64le-linux-musl --no-sysroot-build --type-check-only --cache-dir c --incremental-sema --print-incr-status > o3 2>&1 || true; }
// RUN: %FileCheck %s --check-prefix=HOME2 --input-file=%t.d/o3
// HOME2: incremental: miss: environment changed
// HOME2: main.k:10:16: error [CL001E]: 'kprobe.h' file not found
//
// XDG_CACHE_HOME ahead of HOME: the root with the header again, a miss
// against the second home's record, and clean.
// RUN: cd %t.d && env -u KAIRO_CACHE_DIR -u KAIRO_SYSROOT_CACHE -u LOCALAPPDATA HOME=%t.d/h2 XDG_CACHE_HOME=%t.d/x %kairo main.k --target=powerpc64le-linux-musl --no-sysroot-build --type-check-only --cache-dir c --incremental-sema --print-incr-status > o4 2>&1
// RUN: %FileCheck %s --check-prefix=XDG --input-file=%t.d/o4
// XDG: incremental: miss: environment changed
// XDG-NOT: error
