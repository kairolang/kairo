// glibc's start files without glibc's own LGPL-only sources (Scripts/glibc-own/,
// NOTICE "GNU C Library start files"): the shipped glibc/src has Kairo's replacements
// for csu/init.c, csu/static-reloc.c, aarch64's start.S (2.32/2.33 eras) and __read_tp.S,
// and the generic crti.S/crtn.S, and powerpc32's ppc-mcount.S is dropped. The built
// objects must still carry the symbols the originals defined, and every source the
// tables compile must have the link exception or Kairo's SPDX id.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && %sysgen_env %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// The audit over the shipped tables: no compiled .c/.S source lacks both.
// RUN: python3 %S/../../../Scripts/audit_glibc_exception.py --share %sysgen_share | %FileCheck %s --check-prefix=AUDIT
// AUDIT: 0 file(s) with neither the link exception nor Kairo's SPDX id
//
// x86_64: _IO_stdin_used (4 bytes, .rodata) in both start objects, the empty static-PIE hook in crt1.o.
// RUN: sh %t/ksys.sh build x86_64-linux-gnu-glibc2.42 --libc-only --out %t/x86 2> %t/x86.err
// RUN: %t/tc/bin/llvm-nm -S %t/x86/lib/crt1.o | %FileCheck %s --check-prefix=X86
// RUN: %t/tc/bin/llvm-nm -S %t/x86/lib/Scrt1.o | %FileCheck %s --check-prefix=X86S
// X86: 0000000000000004 R _IO_stdin_used
// X86: 0000000000000001 T _dl_relocate_static_pie
// X86S: 0000000000000004 R _IO_stdin_used
//
// aarch64, pre-2.34 era: _start passes __libc_csu_init / __libc_csu_fini; __read_tp is bti c, mrs, ret.
// RUN: sh %t/ksys.sh build aarch64-linux-gnu-glibc2.31 --libc-only --out %t/a64 2> %t/a64.err
// RUN: %t/tc/bin/llvm-objdump -d -r %t/a64/lib/crt1.o | %FileCheck %s --check-prefix=A64
// A64: <_start>:
// A64-NEXT: bti c
// A64: R_AARCH64_ADD_ABS_LO12_NC __libc_csu_init
// A64: R_AARCH64_ADD_ABS_LO12_NC __libc_csu_fini
// A64: R_AARCH64_CALL26 __libc_start_main
// RUN: %t/tc/bin/llvm-objdump -d %t/a64/lib/libc_nonshared.a | %FileCheck %s --check-prefix=TP
// TP: <__read_tp>:
// TP-NEXT: bti c
// TP-NEXT: mrs x0, TPIDR_EL0
// TP-NEXT: ret
//
// powerpc32: no _mcount object (-pg profiling is unsupported there).
// RUN: sh %t/ksys.sh build powerpc-linux-gnu-glibc2.42 --libc-only --out %t/ppc 2> %t/ppc.err
// RUN: %t/tc/bin/llvm-nm %t/ppc/lib/libc_nonshared.a | %FileCheck %s --check-prefix=PPC
// PPC-NOT: mcount
// PPC: atexit.oS
// PPC-NOT: mcount
//
// RUN: rm -rf %t/cache %t/x86 %t/a64 %t/ppc
