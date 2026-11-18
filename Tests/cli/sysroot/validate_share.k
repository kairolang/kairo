// ksys validate <dir> (Compiler/Spec/SysRoot.md 4.10) now builds and runs the
// share tree's validate/ programs, so it needs that tree: the structural checks
// still run and print first, then a missing share tree is refusal P009E (exit 2)
// with the note naming KAIRO_SYSROOT_SHARE. A broken root stays a failure
// (validate.k's NOMANIFEST / NOLIB cases).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys
// RUN: rm -rf %t && mkdir -p %t/root/include %t/root/lib %t/none
// RUN: printf 'triple = "x86_64-linux-musl"\nclang_triple = "x86_64-unknown-linux-musl"\ninclude_dirs = ["include"]\nlib_dirs = ["lib"]\n' > %t/root/SYSROOT.toml
// RUN: { %ksys --share %t/none validate %t/root 2>&1; echo "exit $?"; } | %FileCheck %s
// CHECK:      triple:       x86_64-linux-musl (linux-musl)
// CHECK-NEXT: clang_triple: x86_64-unknown-linux-musl
// CHECK-NEXT: structure:    ok
// CHECK-NEXT: ksys: error [P009E]: validation needs the share tree: its validate/ programs and the family recipe
// CHECK-NEXT: ksys: note [P009N]: {{.*}}KAIRO_SYSROOT_SHARE
// CHECK-NEXT: exit 2
