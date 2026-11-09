// glibc on MIPS links (P704, SysRoot.md section 22): the linker library knows
// glibc's MIPS loaders, o32 /lib/ld.so.1 and n64 /lib64/ld.so.1 (glibc's
// shlib-versions soname, its configure's rtlddir; Z4's targets.toml `ld`
// agrees), and a MIPS link asks lld for a sysv hash table, as clang's driver
// does: lld refuses .gnu.hash on MIPS, and the "gnu" default failed every link.
// Before, `ksys ensure` built the root and validation stopped at t.c with "no
// known dynamic linker". Link-only: the probes are dynamic, and qemu needs a
// target glibc this tree does not have.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && python3 %S/Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
// RUN: printf 'int main(void) { return 7; }\n' > %t/m.c
//
// RUN: sh %t/ksys.sh ensure mips-linux-gnu-glibc2.42 > %t/o32 2> %t/o32.err
// RUN: %FileCheck %s --check-prefix=O32 < %t/o32.err
// O32: ksys: mips-linux-gnu-glibc2.42: validate: t.c:          built;
// O32: ksys: mips-linux-gnu-glibc2.42: validate: test.k:       built;
// RUN: %t/tc/bin/kcc --target=mips-unknown-linux-gnu --sysroot="$(cat %t/o32)" %t/m.c -o %t/m32
// RUN: %t/tc/bin/llvm-objdump -s -j .interp %t/m32 | %FileCheck %s --check-prefix=I32
// I32: /lib/ld.so.1.
// RUN: %t/tc/bin/llvm-objdump -h %t/m32 | %FileCheck %s --check-prefix=HASH
// HASH-NOT: .gnu.hash
// HASH: .hash
// HASH-NOT: .gnu.hash
//
// RUN: sh %t/ksys.sh ensure mips64el-linux-gnu-glibc2.42 > %t/n64 2> %t/n64.err
// RUN: %FileCheck %s --check-prefix=N64 < %t/n64.err
// N64: ksys: mips64el-linux-gnu-glibc2.42: validate: t.c:          built;
// N64: ksys: mips64el-linux-gnu-glibc2.42: validate: test.k:       built;
// RUN: %t/tc/bin/kcc --target=mips64el-unknown-linux-gnu --sysroot="$(cat %t/n64)" %t/m.c -o %t/m64
// RUN: %t/tc/bin/llvm-objdump -s -j .interp %t/m64 | %FileCheck %s --check-prefix=I64
// I64: /lib64/ld.so.1.
//
// Only the logs are worth keeping.
// RUN: rm -rf %t/cache %t/share/runtimes
