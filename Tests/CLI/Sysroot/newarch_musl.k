// musl on the arches whose backends came after 0.2.1 (SysRoot.md section 21,
// wave Z5): powerpc, powerpc64, powerpc64le, s390x, mips, mipsel, mips64,
// mips64el, loongarch64 (and x32). The share's musl recipe ports them, the
// UAPI carries their kernel ARCH's asm/, and the registered runtimes template
// was derived over their CMake tables, so each is inside the template's
// domain: `ksys tables` instantiates without a refusal, and the probe prints
// the properties the rules were derived for (Names.k properties(), the twin of
// runtimes_template.py props_of).
//
// The root itself is not built here: its validation stops at the Kairo
// library (P700), and a build is minutes per arch.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && python3 %S/Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
// RUN: for n in powerpc-linux-musl powerpc64-linux-musl powerpc64le-linux-musl s390x-linux-musl \
// RUN:     mips-linux-musl mipsel-linux-musl mips64-linux-musl mips64el-linux-musl \
// RUN:     loongarch64-linux-musl; do sh %t/ksys.sh tables $n --out %t/tbl/$n || exit 1; \
// RUN:     test -f %t/tbl/$n/builtins/$n.toml || exit 1; done
//
// RUN: sh %t/ksys.sh probe powerpc64le-linux-musl | %FileCheck %s --check-prefix=PPC
// PPC: supports:     yes
// PPC: properties:   libc=musl os=linux objfmt=elf bits=64 int128=native cpu=powerpc rt_arch=powerpc64le float=na crt_arch=powerpc64le endian=little arch=powerpc64le threads=posix exceptions=dwarf backend=ppc64le
//
// RUN: sh %t/ksys.sh probe mips-linux-musl | %FileCheck %s --check-prefix=MIPS
// MIPS: supports:     yes
// MIPS: properties:   libc=musl os=linux objfmt=elf bits=32 int128=soft cpu=mips rt_arch=mips float=na crt_arch=mips endian=big arch=mips threads=posix exceptions=dwarf backend=mips
//
// RUN: sh %t/ksys.sh probe s390x-linux-musl | %FileCheck %s --check-prefix=S390
// S390: properties:   libc=musl os=linux objfmt=elf bits=64 int128=native cpu=systemz rt_arch=s390x float=na crt_arch=s390x endian=big arch=s390x threads=posix exceptions=dwarf backend=systemz
//
// The kernel headers for an arch come from its kernel ARCH's asm/ dir.
// RUN: test -f %sysgen_share/linux-uapi/asm/powerpc/asm/unistd.h
// RUN: test -f %sysgen_share/linux-uapi/asm/mips/asm/sgidefs.h
// RUN: test -f %sysgen_share/linux-uapi/asm/loongarch/asm/unistd.h
// RUN: rm -rf %t/tbl %t/cache
