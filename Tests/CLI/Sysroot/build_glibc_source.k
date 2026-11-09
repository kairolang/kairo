// glibc from source, any release, any arch (Compiler/Spec/SysRoot.md section 22,
// wave Z4): stubs projected from glibc/abilists at the release asked for, the newest
// release's headers with that release's __GLIBC_MINOR__, crt*.o and
// libc_nonshared.a compiled from glibc/src per glibc/crt/<era>/<arch>.toml.
//
// 2.17 (the floor): glibc's pre-2.34 layout, the 2.32-era start files (__libc_csu_init),
// stat through libc_nonshared.a, and a program built against it binds nothing newer
// than GLIBC_2.17. 2.42 (the newest): SONAME-named files, libpthread a
// placeholder-only library, __libc_start_main@GLIBC_2.34. A release before an arch's
// port is refused by the provider, and --libc-only builds powerpc64le (no runtimes
// table yet) as include/ + lib/ + SYSROOT.toml.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && %sysgen_env %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// RUN: sh %t/ksys.sh build x86_64-linux-gnu-glibc2.17 --out %t/r17 2> %t/err17
// RUN: %FileCheck %s --check-prefix=V17 < %t/err17
// V17: ksys: x86_64-linux-gnu-glibc2.17: validate: t.c:          built, ran, exit 7
// V17-NEXT: ksys: x86_64-linux-gnu-glibc2.17: validate: t.cpp:        built, ran, exit 12
// RUN: grep -c "^#define.__GLIBC_MINOR__.17$" %t/r17/include/features.h
// RUN: cd %t/r17/lib && test -f libc-2.17.so && test "$(readlink libc.so.6)" = libc-2.17.so
// RUN: %t/tc/bin/llvm-nm %t/r17/lib/crt1.o | %FileCheck %s --check-prefix=CRT17
// CRT17: U __libc_csu_init
// RUN: %t/tc/bin/llvm-nm %t/r17/lib/libc_nonshared.a | %FileCheck %s --check-prefix=NS17
// NS17: T __libc_csu_init
// NS17: {{[TW]}} stat
// RUN: %t/tc/bin/llvm-nm -D %t/r17/lib/libc-2.17.so | %FileCheck %s --check-prefix=SYM17
// SYM17-NOT: GLIBC_2.18
// SYM17: {{ }}memcpy@@GLIBC_2.14{{$}}
// SYM17-NOT: GLIBC_2.18
// RUN: echo '#include <stdlib.h>' > %t/h.c && echo '#include <stdio.h>' >> %t/h.c && echo 'int main(void) { printf("%%ld", strtol("42", 0, 10)); return 0; }' >> %t/h.c
// RUN: %t/tc/bin/kcc --target=x86_64-unknown-linux-gnu --sysroot=%t/r17 -std=c2x %t/h.c -o %t/h17
// RUN: %t/h17 | %FileCheck %s --check-prefix=RUN17
// RUN17: 42
// RUN: %t/tc/bin/llvm-nm -D %t/h17 | %FileCheck %s --check-prefix=BIND17
// BIND17-NOT: __isoc23
// BIND17: U strtol@GLIBC_2.2.5
//
// RUN: sh %t/ksys.sh build x86_64-linux-gnu-glibc2.42 --out %t/r42 2> %t/err42
// RUN: %FileCheck %s --check-prefix=V42 < %t/err42
// V42: ksys: x86_64-linux-gnu-glibc2.42: validate: t.c:          built, ran, exit 7
// RUN: cd %t/r42/lib && test -f libc.so.6 && test ! -e libc-2.42.so && test -f libpthread.so.0
// RUN: %t/tc/bin/llvm-nm -D %t/r42/lib/libpthread.so.0 | %FileCheck %s --check-prefix=PT42
// PT42: __libpthread_version_placeholder@GLIBC_2.2.5
// RUN: %t/tc/bin/llvm-nm %t/r42/lib/crt1.o | %FileCheck %s --check-prefix=CRT42
// CRT42-NOT: __libc_csu_init
// CRT42: U __libc_start_main
// RUN: %t/tc/bin/kcc --target=x86_64-unknown-linux-gnu --sysroot=%t/r42 -std=c2x %t/h.c -o %t/h42
// RUN: %t/tc/bin/llvm-nm -D %t/h42 | %FileCheck %s --check-prefix=BIND42
// BIND42: U __isoc23_strtol@GLIBC_2.38
// BIND42: U __libc_start_main@GLIBC_2.34
//
// RUN: not sh %t/ksys.sh build riscv64-linux-gnu-glibc2.26 --out %t/rv 2> %t/errrv
// RUN: %FileCheck %s --check-prefix=FLOOR < %t/errrv
// FLOOR: glibc 2.26 predates the riscv64 port (first release 2.27)
//
// RUN: sh %t/ksys.sh build powerpc64le-linux-gnu-glibc2.42 --libc-only --out %t/ppc 2> %t/errppc
// RUN: test -f %t/ppc/SYSROOT.toml && test -f %t/ppc/include/powerpc64le-linux-gnu/gnu/lib-names-64-v2.h
// RUN: test -f %t/ppc/include/asm/unistd.h && test -f %t/ppc/lib/crt1.o && test -f %t/ppc/lib/ld64.so.2
// RUN: %FileCheck %s --check-prefix=PPC < %t/ppc/lib/libc.so
// PPC: OUTPUT_FORMAT(elf64-powerpcle)
// PPC: GROUP ( libc.so.6 libc_nonshared.a  AS_NEEDED ( ld64.so.2 ) )
//
// RUN: rm -rf %t/cache %t/r17 %t/r42 %t/ppc
