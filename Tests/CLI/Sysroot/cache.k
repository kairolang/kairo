// ksys ensure / ls / rm / gc and the cache layout (Compiler/Spec/SysRoot.md
// 4.3, 4.11, section 7) against the fixture share tree.
//
// No provider builds anything yet (section 11 steps 4-8), so the first ensure
// verifies the inputs, computes the key, takes the lock and then refuses at
// libc-headers, leaving no stage dir behind. A finished sysroot is then put
// under that key by hand: the second ensure finds it, prints its path and
// points by-name at it, without running a stage.

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
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share ensure riscv32-linux-musl 2>&1; echo "exit $?"; } > %t/first.out
// RUN: %FileCheck %s --check-prefix=FIRST < %t/first.out
// FIRST:      ksys: riscv32-linux-musl: key [[KEY:[0-9a-f]{64}]]
// FIRST-NEXT: ksys: riscv32-linux-musl: stage libc-headers
// FIRST-NEXT: ksys: error [P009E]: musl has no ARCH for riscv32: the recipe has no [per_arch.musl_arch] entry
// FIRST-NEXT: exit 2
// A refusal leaves no stage dir (and no .tmp / .failed); the lock and the
// input verification memo stay.
// RUN: test ! -e %t/cache/stage || test -z "$(ls %t/cache/stage)"
// RUN: ls %t/cache/locks | %FileCheck %s --check-prefix=LOCK
// LOCK: {{^[0-9a-f]{64}\.lock$}}
// RUN: test "$(ls %t/cache/verify | wc -l)" -eq 2
//
// The same key on a second run: nothing it hashes changed.
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share ensure riscv32-linux-musl 2>&1 || true; } | sed -n 's/.*key //p' > %t/key2
// RUN: sed -n 's/.*key //p' %t/first.out | diff - %t/key2
//
// A finished sysroot under that key: ensure is a lookup, stdout the path.
// RUN: mkdir -p %t/cache/sysroots/$(cat %t/key2)
// RUN: touch %t/cache/sysroots/$(cat %t/key2)/.ok
// RUN: printf 'triple = "riscv32-linux-musl"\n' > %t/cache/sysroots/$(cat %t/key2)/SYSROOT.toml
// RUN: sh %t/run.sh %t/bin/ksys -q --share %t/share ensure riscv32-linux-musl > %t/path.out
// RUN: %FileCheck %s --check-prefix=HIT < %t/path.out
// HIT: {{.*}}/cache/sysroots/{{[0-9a-f]{64}$}}
// RUN: test -f %t/cache/by-name/riscv32-linux-musl/SYSROOT.toml
// RUN: sh %t/run.sh %t/bin/ksys ls | %FileCheck %s --check-prefix=LS
// LS: riscv32-linux-musl  {{.*}}/cache/sysroots/{{[0-9a-f]{64}$}}
//
// A changed input changes nothing until it is verified: then the hash no
// longer matches the registry, a refusal naming the dir.
// RUN: echo changed >> %t/share/musl/README
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share ensure riscv32-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=MISMATCH
// MISMATCH: ksys: error [P009E]: share input {{.*}}share/musl: tree hash mismatch (registry.toml)
// MISMATCH: exit 2
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share verify-share 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=VERIFY
// VERIFY-DAG: ok        linux-uapi
// VERIFY-DAG: MISMATCH  musl
// VERIFY: ksys: error [P009E]: share input {{.*}}share/musl: tree hash mismatch (registry.toml)
// VERIFY: exit 2
//
// gc keeps a named sysroot and drops an unnamed one; rm drops the name and
// its sysroot; a second rm refuses.
// RUN: mkdir -p %t/cache/sysroots/orphan
// RUN: sh %t/run.sh %t/bin/ksys gc | %FileCheck %s --check-prefix=GC
// GC: removed {{.*}}/cache/sysroots/orphan
// GC-NOT: removed
// RUN: test -d %t/cache/sysroots/$(cat %t/key2)
// RUN: sh %t/run.sh %t/bin/ksys rm riscv32-linux-musl
// RUN: test ! -e %t/cache/sysroots/$(cat %t/key2)
// RUN: sh %t/run.sh %t/bin/ksys ls | count 0
// RUN: { sh %t/run.sh %t/bin/ksys rm riscv32-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=RM
// RM: ksys: error [P009E]: no cached sysroot named riscv32-linux-musl
// RM: exit 2
