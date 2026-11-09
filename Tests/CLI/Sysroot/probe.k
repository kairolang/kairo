// ksys probe (Compiler/Spec/SysRoot.md 4.1-4.2) against a fixture share tree
// (Inputs/share, build/sysroot-share/FORMAT.md): the table, the quirks that
// apply, and each probe refusal (exit 2, one line).
//
// ksys is hardlinked into %t/bin beside empty kcc, kld and llvm-ar, so the
// tool probe sees a release layout whatever this machine has on PATH. Its
// shared libraries stay where they are (LD_LIBRARY_PATH).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, shell, host-linux
// RUN: rm -rf %t && mkdir -p %t/bin %t/lonely %t/empty
// RUN: ln %ksys %t/bin/ksys 2>/dev/null || cp %ksys %t/bin/ksys
// RUN: ln %ksys %t/lonely/ksys 2>/dev/null || cp %ksys %t/lonely/ksys
// RUN: touch %t/bin/kcc %t/bin/kld %t/bin/llvm-ar
// RUN: cp -r %S/Inputs/share %t/share && mkdir -p %t/share/runtimes
// RUN: %ksys --print-runtimes-revision > %t/share/runtimes/REVISION
// RUN: echo 'env LD_LIBRARY_PATH="$(dirname %ksys)/../lib" KAIRO_SYSROOT_CACHE=%t/cache "$@"' > %t/run.sh
//
// x86_64: 64-bit, so int128 holds and int128-software does not apply.
// RUN: sh %t/run.sh %t/bin/ksys --share %t/share probe x86_64-linux-musl | %FileCheck %s --check-prefix=X64
// X64:      name:         x86_64-linux-musl
// X64-NEXT: family:       linux-musl
// X64-NEXT: provider:     musl
// X64-NEXT: share:        {{.*}}share
// X64-NEXT: runtimes:     {{.+}}
// X64-NEXT: backend:      ok
// X64-NEXT: int128:       yes
// X64-NEXT: clang_triple: x86_64-unknown-linux-musl
// X64-NEXT: quirks:       (none)
// X64-NEXT: supports:     yes
// X64-NEXT: tools:        ok
//
// armv7: the recipe's clang_triple, rewritten by the hard-float quirk; no
// native int128, so the software one applies.
// RUN: sh %t/run.sh %t/bin/ksys --share %t/share probe armv7-linux-musl | %FileCheck %s --check-prefix=ARM
// ARM: int128:       no
// ARM: clang_triple: armv7-unknown-linux-musleabihf
// ARM: quirks:       armv7-musl-hardfloat, int128-software
//
// An arch the family table has but the recipe does not port.
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share probe i686-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=NOPORT
// NOPORT: supports:     no
// NOPORT: ksys: error [P009E]: linux-musl has no port for i686
// NOPORT: exit 2
//
// glibc versions: outside the shipped set, below the floor, --glibc on musl.
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share probe x86_64-linux-gnu-glibc2.35 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=GSET
// GSET: ksys: error [P009E]: glibc 2.35 is not in the shipped set 2.28, 2.31
// GSET: exit 2
// RUN: sh %t/run.sh %t/bin/ksys --share %t/share probe x86_64-linux-gnu | %FileCheck %s --check-prefix=GDEF
// GDEF: name:         x86_64-linux-gnu-glibc2.31
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share --glibc=2.28 probe x86_64-linux-gnu 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=G28
// G28: name:         x86_64-linux-gnu-glibc2.28
// G28: exit 0
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share --glibc=2.31 probe x86_64-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=GMUSL
// GMUSL: ksys: error [P009E]: --glibc applies to glibc targets, and x86_64-linux-musl is not one
// GMUSL: exit 2
//
// A user-provider family names the --input it needs and the marker file.
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/share probe x86_64-windows-msvc 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=MSVC
// MSVC: supports:     no
// MSVC: ksys: error [P009E]: windows-msvc needs --input DIR (an MSVC + Windows SDK splat, as xwin or scripts/msvc-sysroot.sh lays out); marker crt/include/vcruntime.h not found
// MSVC: exit 2
// RUN: mkdir -p %t/splat/crt/include && touch %t/splat/crt/include/vcruntime.h
// RUN: sh %t/run.sh %t/bin/ksys --share %t/share --input %t/splat probe x86_64-windows-msvc | %FileCheck %s --check-prefix=SPLAT
// SPLAT: supports:     yes
//
// No kcc beside ksys and an empty PATH.
// RUN: { env PATH=%t/empty LD_LIBRARY_PATH="$(dirname %ksys)/../lib" %t/lonely/ksys --share %t/share probe x86_64-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=TOOLS
// TOOLS: tools:        kcc missing
// TOOLS: ksys: error [P009E]: kcc not found beside {{.*}}lonely or on PATH
// TOOLS: exit 2
//
// The runtimes revision must match the compiler's.
// RUN: cp -r %t/share %t/stale && echo 0000 > %t/stale/runtimes/REVISION
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/stale probe x86_64-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=REV
// REV: ksys: error [P009E]: runtimes/REVISION 0000 does not match the compiler ({{.+}}); reinstall the toolchain
// REV: exit 2
//
// quirks.toml is schema-checked: an unknown key names its quirk.
// RUN: cp -r %t/share %t/badq && printf '[quirk.typo]\nmatch_arch = ["x86_64"]\ncflag_add = ["-O3"]\n' > %t/badq/quirks.toml
// RUN: { sh %t/run.sh %t/bin/ksys --share %t/badq probe x86_64-linux-musl 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=BADQ
// BADQ: ksys: error [P009E]: {{.*}}quirks.toml: quirk typo: unknown key cflag_add
// BADQ: exit 2
