// The Kairo library builds and runs on the big-endian, 32-bit and non-x86
// targets whose float formats lack f16 / bf16 / f128 / f80: those formatting
// functions are gated on target macros, so the library compiles for
// powerpc64le, mips, s390x and loongarch64, `ksys ensure` validates each root
// through test.k, and a Kairo program that formats an f64 and an i32 links and
// runs under user-mode QEMU.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// REQUIRES: qemu-ppc64le, qemu-mips, qemu-s390x, qemu-loongarch64
// RUN: rm -rf %t && python3 %S/../Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
// RUN: printf 'import std::io\n\nfn main() -> i32 {\n    var a: f64 = -1.5\n    io::println(f"hello {a} {7}")\n    return 3\n}\n' > %t/h.k
//
// RUN: sh %t/ksys.sh ensure powerpc64le-linux-musl > %t/ppc.path 2> %t/ppc.err
// RUN: %FileCheck %s --check-prefix=PPCV < %t/ppc.err
// PPCV: ksys: powerpc64le-linux-musl: validate: test.k:       built, ran, exit 0
// RUN: %t/tc/bin/kairo %t/h.k --target=powerpc64le-linux-musl --sysroot="$(cat %t/ppc.path)" -o %t/h.ppc --cache-dir %t/kc
// RUN: { %qemu_ppc64le %t/h.ppc || echo "exit $?"; } | %FileCheck %s --check-prefix=OUT
//
// RUN: sh %t/ksys.sh ensure mips-linux-musl > %t/mips.path 2> %t/mips.err
// RUN: %FileCheck %s --check-prefix=MIPSV < %t/mips.err
// MIPSV: ksys: mips-linux-musl: validate: test.k:       built, ran, exit 0
// RUN: %t/tc/bin/kairo %t/h.k --target=mips-linux-musl --sysroot="$(cat %t/mips.path)" -o %t/h.mips --cache-dir %t/kc
// RUN: { %qemu_mips %t/h.mips || echo "exit $?"; } | %FileCheck %s --check-prefix=OUT
//
// RUN: sh %t/ksys.sh ensure s390x-linux-musl > %t/s390.path 2> %t/s390.err
// RUN: %FileCheck %s --check-prefix=S390V < %t/s390.err
// S390V: ksys: s390x-linux-musl: validate: test.k:       built, ran, exit 0
// RUN: %t/tc/bin/kairo %t/h.k --target=s390x-linux-musl --sysroot="$(cat %t/s390.path)" -o %t/h.s390 --cache-dir %t/kc
// RUN: { %qemu_s390x %t/h.s390 || echo "exit $?"; } | %FileCheck %s --check-prefix=OUT
//
// RUN: sh %t/ksys.sh ensure loongarch64-linux-musl > %t/loong.path 2> %t/loong.err
// RUN: %FileCheck %s --check-prefix=LOONGV < %t/loong.err
// LOONGV: ksys: loongarch64-linux-musl: validate: test.k:       built, ran, exit 0
// RUN: %t/tc/bin/kairo %t/h.k --target=loongarch64-linux-musl --sysroot="$(cat %t/loong.path)" -o %t/h.loong --cache-dir %t/kc
// RUN: { %qemu_loongarch64 %t/h.loong || echo "exit $?"; } | %FileCheck %s --check-prefix=OUT
//
// OUT: hello -1.5 7
// OUT-NEXT: exit 3
// RUN: rm -rf %t/cache %t/kc %t/share/runtimes
