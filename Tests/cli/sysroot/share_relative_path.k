// A relative --share (or KAIRO_SYSROOT_SHARE) is made absolute and
// normalised when the share is located, so the path the stages map with
// -ffile-prefix-map names the same files the compiler records, and two builds
// from differently spelled relative shares are byte-identical. The probe prints
// the located share: a relative spelling with `..` or a symlink comes back as
// one absolute path, the same as the absolute spelling.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && python3 %S/inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: mkdir -p %t/sub && ln -s %t/share %t/lnk
// RUN: export KAIRO_SYSROOT_CACHE=%t/cache
// RUN: cd %t/sub && %t/tc/bin/ksys --share ../share probe x86_64-linux-musl | %FileCheck %s --check-prefix=REL --implicit-check-not='..'
// REL: share:        {{.*}}/share{{$}}
// RUN: cd %t/sub && %t/tc/bin/ksys --share ../lnk probe x86_64-linux-musl | %FileCheck %s --check-prefix=LNK --implicit-check-not='..'
// LNK: share:        {{/.*}}{{$}}
// RUN: cd %t/sub && env KAIRO_SYSROOT_SHARE=../share %t/tc/bin/ksys probe x86_64-linux-musl | %FileCheck %s --check-prefix=ENV --implicit-check-not='..'
// ENV: share:        {{/.*}}/share{{$}}
//
// An absolute share is kept as given.
// RUN: %t/tc/bin/ksys --share %t/share probe x86_64-linux-musl | %FileCheck %s --check-prefix=ABS -DSHARE=%t/share
// ABS: share:        [[SHARE]]{{$}}
//
// A share path that does not exist is still refused.
// RUN: { cd %t/sub && %t/tc/bin/ksys --share ../nope probe x86_64-linux-musl 2>&1 || true; } | %FileCheck %s --check-prefix=NONE
// NONE: error
// RUN: rm -rf %t/cache
