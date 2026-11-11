// --target is canonicalised once, before anything reads it. A glibc
// version, Zig's `.2.28` or ours `-glibc2.28`, names the sysroot only: clang
// gets the plain triple, the env macro is the plain environment, and the
// root is the one for that version, never the bundled 2.31 found by spelling.
// kcc reaches the same driver, so both spellings are checked through it
// (-### prints the cc1 lines without running them). A cached root stands in
// for the build ksys would otherwise run.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: rm -rf %t && mkdir -p %t/cache/sysroots/k1/include %t/cache/by-name
// RUN: printf 'triple = "aarch64-linux-gnu-glibc2.28"\nclang_triple = "aarch64-unknown-linux-gnu"\ninclude_dirs = ["include"]\nlib_dirs = ["include"]\n' > %t/cache/sysroots/k1/SYSROOT.toml
// RUN: ln -s ../sysroots/k1 %t/cache/by-name/aarch64-linux-gnu-glibc2.28
// RUN: printf 'int main(void) { return 0; }\n' > %t/c.c
//
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache %kcc --target=aarch64-linux-gnu.2.28 -### -c %t/c.c > %t/zig.out 2>&1
// RUN: %FileCheck %s --check-prefix=CANON < %t/zig.out
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache %kcc --target=aarch64-linux-gnu-glibc2.28 -### -c %t/c.c > %t/ours.out 2>&1
// RUN: %FileCheck %s --check-prefix=CANON < %t/ours.out
// CANON-NOT: 2.28
// CANON:     -triple aarch64-unknown-linux-gnu{{ }}
// CANON-NOT: 2.28
// CANON:     -D__kairo_env_gnu__=1
// CANON-NOT: 2.28
// CANON:     -isysroot {{[^ ]*}}/cache/sysroots/k1
// CANON-NOT: 2.28
