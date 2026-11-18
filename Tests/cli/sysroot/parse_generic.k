// ksys parse beyond the built-in table (Compiler/Spec/SysRoot.md section 2,
// SysRoot.md section 19): any well-formed triple whose OS and environment
// name one of the families is a target, its arch spelled as the triple
// spells it; whether anything can build it is the provider's question,
// asked later. Zig's glibc spelling `<...>-gnu.<X.Y>` is `-glibc<X.Y>`.
// Soft-float Arm on Linux is refused (every root is hard-float), and an OS
// no family covers is still "not a sysroot name".
fn main() -> i32 { return 0 }
// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys
// RUN: rm -rf %t && mkdir -p %t
// RUN: for t in aarch64_be-unknown-linux-musl thumbv7-unknown-linux-musleabihf \
// RUN:     riscv32-unknown-linux-gnu x86_64-linux-gnu.2.17 armv7-linux-gnueabihf.2.31 \
// RUN:     riscv32-unknown-linux-musl i686-pc-windows-gnu; do \
// RUN:   { %ksys --share %t/none probe $t 2>/dev/null || true; } | head -3; done | %FileCheck %s --check-prefix=GEN
// GEN:      name:         aarch64_be-linux-musl
// GEN-NEXT: family:       linux-musl
// GEN-NEXT: provider:     musl
// GEN-NEXT: name:         thumbv7-linux-musl
// GEN-NEXT: family:       linux-musl
// GEN-NEXT: provider:     musl
// GEN-NEXT: name:         riscv32-linux-gnu-glibc2.31
// GEN-NEXT: family:       linux-gnu
// GEN-NEXT: provider:     glibc
// GEN-NEXT: name:         x86_64-linux-gnu-glibc2.17
// GEN-NEXT: family:       linux-gnu
// GEN-NEXT: provider:     glibc
// GEN-NEXT: name:         armv7-linux-gnueabihf-glibc2.31
// GEN-NEXT: family:       linux-gnu
// GEN-NEXT: provider:     glibc
// GEN-NEXT: name:         riscv32-linux-musl
// GEN-NEXT: family:       linux-musl
// GEN-NEXT: provider:     musl
// GEN-NEXT: name:         i686-windows-gnu
// GEN-NEXT: family:       windows-gnu
// GEN-NEXT: provider:     mingw
//
// RUN: %ksys --share %t/none probe armv7-unknown-linux-musleabi > %t/soft.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=SOFT < %t/soft.out
// SOFT: ksys: error [P009E]: 'armv7-unknown-linux-musleabi' is soft-float Arm; sysroots are built for musleabihf only
// RUN: %ksys --share %t/none probe x86_64-unknown-linux-android > %t/env.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=ENV < %t/env.out
// ENV: ksys: error [P009E]: 'x86_64-unknown-linux-android': Linux sysroots are musl or gnu, not android
// RUN: %ksys --share %t/none probe sparc-sun-solaris > %t/unk.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=UNKNOWN < %t/unk.out
// UNKNOWN: ksys: error [P009E]: 'sparc-sun-solaris' is not a sysroot name, or the triple of one
