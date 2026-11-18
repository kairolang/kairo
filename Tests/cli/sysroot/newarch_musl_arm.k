// musl on thumbv7 and big-endian aarch64: both are inside the share's musl
// recipe (per_arch rows, UAPI alias, Arm quirk key), so `ksys tables`
// instantiates without a refusal and the probe reports them supported. thumbv7
// maps to the hard-float musleabihf triple. An arch with no row (sparc) is
// still refused with "has no port", so the rows are what admit an arch.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && python3 %S/inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
// RUN: for n in thumbv7-linux-musl aarch64_be-linux-musl; do \
// RUN:     sh %t/ksys.sh tables $n --out %t/tbl/$n || exit 1; \
// RUN:     test -f %t/tbl/$n/builtins/$n.toml || exit 1; done
//
// RUN: sh %t/ksys.sh probe thumbv7-linux-musl | %FileCheck %s --check-prefix=THUMB
// THUMB: clang_triple: thumbv7-unknown-linux-musleabihf
// THUMB: supports:     yes
// THUMB: properties:   libc=musl os=linux objfmt=elf bits=32 {{.*}} arch=thumbv7 {{.*}} backend=thumb
//
// RUN: sh %t/ksys.sh probe aarch64_be-linux-musl | %FileCheck %s --check-prefix=BE
// BE: supports:     yes
// BE: properties:   libc=musl os=linux objfmt=elf bits=64 {{.*}} endian=big arch=aarch64_be {{.*}} backend=aarch64_be
//
// RUN: { sh %t/ksys.sh tables sparc-linux-musl --out %t/tbl/sparc 2>&1 || true; } | %FileCheck %s --check-prefix=NOPORT --implicit-check-not='error ['
// NOPORT: error [P009E]: linux-musl has no port for sparc
// RUN: rm -rf %t/tbl %t/cache
