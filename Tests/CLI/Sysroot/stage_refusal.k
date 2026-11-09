// The musl provider's stages against the fixture share tree, which holds no
// musl source (Compiler/Spec/SysRoot.md 4.4, section 9): a target the recipe
// gives no [per_arch.musl_arch] is a refusal naming the missing entry, and one
// it does give is refused for the tree that lacks arch/<ARCH>. Both are exit 2,
// and a refusal leaves no stage dir behind (only a failure keeps a .failed log).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, shell, host-linux
// RUN: rm -rf %t && mkdir -p %t/bin
// RUN: ln %ksys %t/bin/ksys 2>/dev/null || cp %ksys %t/bin/ksys
// RUN: touch %t/bin/kcc %t/bin/kld %t/bin/llvm-ar
// RUN: cp -r %S/Inputs/share %t/share && mkdir -p %t/share/runtimes
// RUN: %ksys --print-runtimes-revision > %t/share/runtimes/REVISION
// RUN: echo 'env LD_LIBRARY_PATH="$(dirname %ksys)/../lib" KAIRO_SYSROOT_CACHE=%t/cache "$@"' > %t/run.sh
//
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share ensure riscv32-linux-musl 2>&1; echo "exit $?"; } > %t/rv.out
// RUN: %FileCheck %s --check-prefix=NOARCH < %t/rv.out
// NOARCH:      ksys: riscv32-linux-musl: stage libc-headers
// NOARCH-NEXT: ksys: error [P009E]: musl has no ARCH for riscv32: the recipe has no [per_arch.musl_arch] entry
// NOARCH-NEXT: exit 2
// RUN: test ! -e %t/cache/stage || test -z "$(ls %t/cache/stage)"
//
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share ensure x86_64-linux-musl 2>&1; echo "exit $?"; } > %t/x.out
// RUN: %FileCheck %s --check-prefix=NOTREE < %t/x.out
// NOTREE:      ksys: x86_64-linux-musl: stage libc-headers
// NOTREE-NEXT: ksys: error [P009E]: share input {{.*}}/share/musl is not a musl source tree with arch/x86_64
// NOTREE-NEXT: exit 2
// RUN: test ! -e %t/cache/stage || test -z "$(ls %t/cache/stage)"
