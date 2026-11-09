// ksys validate <dir> (Compiler/Spec/SysRoot.md 4.10): the manifest and the
// directories it names are checked; the build-and-run steps are refused as not
// implemented yet (exit 2), so a pass is never claimed for what was not run.
// A broken root is a validation failure, exit 3.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys
// RUN: rm -rf %t && mkdir -p %t/root/include %t/root/lib %t/empty
// RUN: printf 'triple = "x86_64-linux-musl"\nclang_triple = "x86_64-unknown-linux-musl"\ninclude_dirs = ["include"]\nlib_dirs = ["lib"]\n' > %t/root/SYSROOT.toml
// RUN: { %ksys validate %t/root 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=OK
// OK: triple:       x86_64-linux-musl (linux-musl)
// OK: clang_triple: x86_64-unknown-linux-musl
// OK: structure:    ok
// OK: ksys: error [P009E]: validation steps symbols, replay, kairo and run are not implemented yet
// OK: exit 2
//
// RUN: { %ksys validate %t/empty 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=NOMANIFEST
// NOMANIFEST: ksys: error [P010E]: validation failed at manifest: {{.*}}empty/SYSROOT.toml is missing
// NOMANIFEST: exit 3
//
// RUN: rmdir %t/root/lib
// RUN: { %ksys validate %t/root 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=NOLIB
// NOLIB: ksys: error [P010E]: validation failed at manifest: lib_dirs entry lib is not a directory under {{.*}}root
// NOLIB: exit 3
