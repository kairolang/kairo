// ksys ensure x86_64-linux-musl from the real share tree (Compiler/Spec/SysRoot.md
// section 10 build/): musl's headers installed and libc.a + crt objects compiled
// from source by the musl provider, the root assembled, its SYSROOT.toml rendered
// byte for byte as the curated one, then validated by building t.c, t.cpp and the
// three .k programs against it and running them natively. A second ensure is a
// lookup: no stage runs and stdout is the same path.
//
// The builtins and runtimes stages compile the runtimes source that ksys_env.py
// stages into the share view; ksys runs from a scratch toolchain prefix
// with no sysroot/ so that validation builds against the generated root, not a
// bundled one (the driver prefers <prefix>/sysroot/<name> over --sysroot).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64
// RUN: rm -rf %t && %sysgen_env %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// RUN: sh %t/ksys.sh ensure x86_64-linux-musl > %t/path1 2> %t/err1
// RUN: %FileCheck %s --check-prefix=FIRST < %t/err1
// FIRST:      ksys: x86_64-linux-musl: key {{[0-9a-f]{64}$}}
// FIRST-NEXT: ksys: x86_64-linux-musl: stage libc-headers
// FIRST-NEXT: ksys: x86_64-linux-musl: stage builtins
// FIRST-NEXT: ksys: x86_64-linux-musl: stage libc-libs
// FIRST-NEXT: ksys: x86_64-linux-musl: stage runtimes
// FIRST-NEXT: ksys: x86_64-linux-musl: stage assemble
// FIRST-NEXT: ksys: x86_64-linux-musl: stage toml
// FIRST-NEXT: ksys: x86_64-linux-musl: stage validate
// FIRST:      ksys: x86_64-linux-musl: validate: structure:    ok
// FIRST-NEXT: ksys: x86_64-linux-musl: validate: t.c:          built, ran, exit 7
// FIRST-NEXT: ksys: x86_64-linux-musl: validate: t.cpp:        built, ran, exit 12
// FIRST-NEXT: ksys: x86_64-linux-musl: validate: test.k:       built, ran, exit 0
// FIRST-NEXT: ksys: x86_64-linux-musl: validate: floats.k:     built, ran, exit 5
// FIRST-NEXT: ksys: x86_64-linux-musl: validate: tfbf.k:       built, ran, exit 1
// RUN: %FileCheck %s --check-prefix=PATH < %t/path1
// PATH: {{^.*}}/cache/sysroots/{{[0-9a-f]{64}$}}
// PATH-NOT: {{.}}
//
// The root: the curated TOML byte for byte, musl's libraries, the licenses, the key.
// RUN: diff %sysgen_rt/x86_64-linux-musl/SYSROOT.toml "$(cat %t/path1)/SYSROOT.toml"
// RUN: test -f "$(cat %t/path1)/lib/libc.a" && test -f "$(cat %t/path1)/lib/crt1.o" && test -f "$(cat %t/path1)/lib/crti.o"
// RUN: test "$(wc -c < "$(cat %t/path1)/lib/libm.a")" -eq 8
// RUN: test -f "$(cat %t/path1)/include/bits/alltypes.h" && test -f "$(cat %t/path1)/include/linux/version.h"
// RUN: test -f "$(cat %t/path1)/compiler-rt/lib/x86_64-unknown-linux-musl/libclang_rt.builtins.a"
// RUN: test -f "$(cat %t/path1)/LICENSES/musl/COPYRIGHT" && test -d "$(cat %t/path1)/LICENSES/linux-uapi"
// RUN: grep -q '"generated_by":"ksys ' "$(cat %t/path1)/.kairo-sysroot.json"
// RUN: test "$(readlink %t/cache/by-name/x86_64-linux-musl)" = "../sysroots/$(basename "$(cat %t/path1)")"
//
// RUN: sh %t/ksys.sh ensure x86_64-linux-musl > %t/path2 2> %t/err2
// RUN: diff %t/path1 %t/path2
// RUN: not grep stage %t/err2
//
// Only the logs are worth keeping: the cache holds two hundred MB of root.
// RUN: rm -rf %t/cache
