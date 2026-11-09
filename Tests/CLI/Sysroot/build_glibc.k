// ksys ensure x86_64-linux-gnu-glibc2.31 from the real share tree (Compiler/Spec/
// SysRoot.md 4.4, 4.6): the shipped headers and crt objects, link-time stub DSOs
// generated from the abilists (kcc compiles, kld links, one per library), the
// libc.so / libm.so linker scripts and the dev links; then validation links the
// probes against the stubs and runs them on the host's glibc. TOML byte-identical
// to the curated root's. Builtins and runtimes as in build_musl.k.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && %sysgen_env %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// RUN: sh %t/ksys.sh ensure x86_64-linux-gnu-glibc2.31 > %t/path 2> %t/err
// RUN: %FileCheck %s --check-prefix=VAL < %t/err
// VAL: ksys: x86_64-linux-gnu-glibc2.31: stage libc-libs
// VAL: ksys: x86_64-linux-gnu-glibc2.31: validate: t.c:          built, ran, exit 7
// VAL-NEXT: ksys: x86_64-linux-gnu-glibc2.31: validate: t.cpp:        built, ran, exit 12
// VAL-NEXT: ksys: x86_64-linux-gnu-glibc2.31: validate: test.k:       built, ran, exit 0
// RUN: diff %sysgen_rt/x86_64-linux-gnu-glibc2.31/SYSROOT.toml "$(cat %t/path)/SYSROOT.toml"
//
// glibc 2.31's install layout: lib<x>-2.31.so, the SONAME a link to it, -l<x> a dev link.
// RUN: cd "$(cat %t/path)/lib" && test -f libc-2.31.so && test "$(readlink libc.so.6)" = libc-2.31.so
// RUN: cd "$(cat %t/path)/lib" && test "$(readlink ld-linux-x86-64.so.2)" = ld-2.31.so
// RUN: cd "$(cat %t/path)/lib" && test "$(readlink libpthread.so)" = libpthread.so.0
// RUN: %FileCheck %s --check-prefix=LIBC < "$(cat %t/path)/lib/libc.so"
// LIBC:      OUTPUT_FORMAT(elf64-x86-64)
// LIBC-NEXT: GROUP ( libc.so.6 libc_nonshared.a  AS_NEEDED ( ld-linux-x86-64.so.2 ) )
// RUN: %FileCheck %s --check-prefix=LIBM < "$(cat %t/path)/lib/libm.so"
// LIBM: GROUP ( libm.so.6  AS_NEEDED ( libmvec.so.1 ) )
//
// A stub keeps @ (compat) and @@ (default) apart, and the version-name symbols.
// RUN: %t/tc/bin/llvm-nm -D "$(cat %t/path)/lib/libc-2.31.so" > %t/dynsym
// RUN: %FileCheck %s --check-prefix=SYM < %t/dynsym
// SYM-DAG: {{ }}memcpy@@GLIBC_2.14{{$}}
// SYM-DAG: {{ }}memcpy@GLIBC_2.2.5{{$}}
// SYM-DAG: {{ }}GLIBC_2.30@@GLIBC_2.30{{$}}
//
// Only the logs are worth keeping: the cache holds two hundred MB of root.
// RUN: rm -rf %t/cache
