// The runtimes template (build/sysroot-share/FORMAT.md, "runtimes-template";
// SysRoot.md section 19): Scripts/runtimes_template.py derives it from the
// runtimes-recipe/ tables and checks that every table comes back from it;
// ksys, given a share tree that registers the template and not the tables,
// instantiates exactly those tables (`ksys tables`), compile for compile and
// archive member for member, and builds byte-identical archives from them.
// A target with a property value the rules were not derived over is refused
// before any stage, and the probe prints the properties the rules read.
//
// The template here is made from the 18 shipped tables alone, so armv6
// musl (rt_arch=armv6, derived only from an EXTRA table) is outside it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64
// RUN: rm -rf %t && python3 %S/Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: python3 %S/../../../Scripts/runtimes_template.py --recipe %sysgen_share/runtimes-recipe --out %t/tmpl > %t/gen.out
// RUN: %FileCheck %s --check-prefix=GEN < %t/gen.out
// GEN:     template: 18 targets
// GEN-NOT: DIFF
// GEN:     x86_64-windows-gnu: trained: IDENTICAL
//
// RUN: python3 %S/Inputs/ksys_template_env.py view %t/share %t/tmpl %t/tshare
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/tshare "$@"' > %t/ksys.sh
// RUN: for n in x86_64-linux-musl aarch64-windows-gnu wasm32-wasi x86_64-unknown-freebsd \
// RUN:     armv7-linux-gnueabihf-glibc2.31; do sh %t/ksys.sh tables $n --out %t/tbl || exit 1; done
// RUN: python3 %S/Inputs/ksys_template_env.py cmp %t/tbl %sysgen_share/runtimes-recipe x86_64-linux-musl \
// RUN:     aarch64-windows-gnu wasm32-wasi x86_64-unknown-freebsd armv7-linux-gnueabihf-glibc2.31 > %t/cmp.out
// RUN: %FileCheck %s --check-prefix=CMP < %t/cmp.out
// CMP:      x86_64-linux-musl: IDENTICAL
// CMP-NEXT: aarch64-windows-gnu: IDENTICAL
// CMP-NEXT: wasm32-wasi: IDENTICAL
// CMP-NEXT: x86_64-unknown-freebsd: IDENTICAL
// CMP-NEXT: armv7-linux-gnueabihf-glibc2.31: IDENTICAL
//
// RUN: { sh %t/ksys.sh tables armv6-linux-musl --out %t/a6 2>&1; echo "exit $?"; } > %t/dom.out
// RUN: %FileCheck %s --check-prefix=DOMAIN < %t/dom.out
// DOMAIN:      ksys: error [P009E]: the runtimes template has no rule for rt_arch=armv6 (armv6-linux-musl); it was derived for rt_arch in {{.*}}armhf, i386{{.*}}
// DOMAIN-NEXT: ksys: note [P009N]: runtimes-template/index.toml [domain] lists what its rules were derived over
// DOMAIN-NEXT: exit 2
//
// RUN: sh %t/ksys.sh probe aarch64-windows-gnu | %FileCheck %s --check-prefix=PROPS
// PROPS: properties:   libc=mingw os=windows objfmt=coff bits=64 int128=native cpu=aarch64 rt_arch=aarch64 float=na crt_arch=aarch64 endian=little arch=aarch64 threads=win32 exceptions=seh backend=aarch64
//
// The same builtins archive from the template as from the tables, byte for byte.
// RUN: sh %t/ksys.sh build wasm32-wasi --out %t/wt > %t/wt.log 2>&1
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share build wasm32-wasi --out %t/wr > %t/wr.log 2>&1
// RUN: cmp %t/wt/compiler-rt/lib/wasm32-unknown-wasi/libclang_rt.builtins.a %t/wr/compiler-rt/lib/wasm32-unknown-wasi/libclang_rt.builtins.a
//
// Only the logs are worth keeping.
// RUN: rm -rf %t/wt %t/wr %t/rt %t/cache %t/tbl
