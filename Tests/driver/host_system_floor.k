// The default build (no --target, no --native) on a glibc Linux host is
// <arch>-unknown-linux-gnu against the bundled glibc 2.31 sysroot, the floor.
// The host's own system include dirs come after every sysroot root, as
// -idirafter: libc++, then clang's builtin headers, then the floor's libc,
// and only then /usr/include, so <stdio.h> is always the floor's and only a
// header the floor lacks (zlib.h, curl/curl.h) is the host's.
//
// --target is hermetic: the bundled sysroot only, no host dir anywhere.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc
// RUN: %kairo %s --print-clang-args | %FileCheck %s --check-prefix=FLOOR
// FLOOR:      clang -cc1 -triple {{[a-z0-9_]+}}-unknown-linux-gnu
// FLOOR-SAME: -isystem {{[^ ]*}}glibc2.31/include/c++/v1
// FLOOR-SAME: -isystem {{[^ ]*}}/clang/{{[0-9]+}}/include
// FLOOR-SAME: -isystem {{[^ ]*}}glibc2.31/include
// FLOOR-SAME: -idirafter /usr/include
// FLOOR-SAME: -isysroot {{[^ ]*}}glibc2.31
// FLOOR-NOT:  -isystem /usr

// --version and --print-dirs name the same target and the floor's sysroot;
// the host's library dirs are listed apart, after it.
// RUN: %kairo --version | %FileCheck %s --check-prefix=VER
// VER: target triple: {{ *}}{{[a-z0-9_]+}}-unknown-linux-gnu
// VER: sysroot: {{ *}}{{[^ ]*}}glibc2.31
// RUN: %kairo %s --print-dirs | %FileCheck %s --check-prefix=DIRS
// DIRS:      sysroot: {{ *}}{{[^ ]*}}glibc2.31 (manifest)
// DIRS:      library search:
// DIRS-NEXT:   {{[^ ]*}}glibc2.31/lib
// DIRS:      host library search (after the sysroot):

// RUN: %kairo %s --print-clang-args --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=HERM
// HERM:     clang -cc1 -triple x86_64-linux-gnu
// HERM-NOT: -idirafter
// HERM-NOT: /usr/include
// RUN: %kairo %s --print-dirs --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=HERMDIRS
// HERMDIRS:     library search:
// HERMDIRS-NOT: host library search
