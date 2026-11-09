// The driver's --target hook (Compiler/Spec/SysRoot.md section 8): with no
// --sysroot and no bundled root for the target, kairo looks in the
// generator's cache (<cache>/by-name/<name>), then runs ksys's ensure
// in-process. riscv32-linux-musl has no bundled root in any tree.
//
//   - --no-sysroot-build: the missing root is refusal P009E, exit 2.
//   - a cached root is found (--version reports it, no build).
//   - a share tree present: "building sysroot ..." on stderr, then ensure's
//     own refusal (no provider builds yet), exit 2.
//   - no share tree: today's P008W warning, nothing built.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, long-tests
// RUN: rm -rf %t && mkdir -p %t/cache/sysroots/k1/include %t/cache/by-name %t/empty
//
// RUN: env KAIRO_SYSROOT_CACHE=%t/empty %kairo %s --type-check-only --target=riscv32-linux-musl --no-sysroot-build > %t/refuse.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=REFUSE < %t/refuse.out
// REFUSE: error [P009E]: no sysroot for target 'riscv32-linux-musl': none is installed or cached, and --no-sysroot-build forbids building one
// REFUSE: note [P009N]: pass --sysroot=<dir>, or drop --no-sysroot-build to let ksys build it
// REFUSE-NOT: P008W
//
// RUN: printf 'triple = "riscv32-linux-musl"\ninclude_dirs = ["include"]\nlib_dirs = ["include"]\n' > %t/cache/sysroots/k1/SYSROOT.toml
// RUN: ln -s ../sysroots/k1 %t/cache/by-name/riscv32-linux-musl
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache %kairo --target=riscv32-linux-musl --version | %FileCheck %s --check-prefix=CACHED
// CACHED: sysroot:           {{.*}}/cache/{{(by-name/riscv32-linux-musl|sysroots/k1)$}}
//
// RUN: cp -r %S/Inputs/share %t/share && mkdir -p %t/share/runtimes
// RUN: %ksys --print-runtimes-revision > %t/share/runtimes/REVISION
// RUN: env KAIRO_SYSROOT_CACHE=%t/empty KAIRO_SYSROOT_SHARE=%t/share %kairo %s --type-check-only --target=riscv32-linux-musl > %t/ensure.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=ENSURE < %t/ensure.out
// ENSURE: building sysroot for riscv32-linux-musl, first time only
// ENSURE: error [P009E]:
// ENSURE-NOT: P008W
//
// RUN: { env KAIRO_SYSROOT_CACHE=%t/empty %kairo %s --type-check-only --target=riscv32-linux-musl 2>&1 || true; } | %FileCheck %s --check-prefix=NOSHARE
// NOSHARE-NOT: building sysroot
// NOSHARE: warning [P008W]: no sysroot found for target 'riscv32-linux-musl'
