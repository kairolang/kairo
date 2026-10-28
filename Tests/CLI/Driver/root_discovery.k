// With no --resource-dir, --builtins-dir or --std-dir the driver takes them
// from the toolchain layout beside the binary (<exe>/../lib/clang/<ver>,
// <exe>/../lib/builtin, <exe>/../lib/std), and warns once per root it cannot
// find, naming the path searched and the flag that overrides it. No usable
// sysroot is a warning too, unless --freestanding asked for none.
//
// The binary is HARDLINKED into a fresh layout under %t: a symlink would not
// do, the driver resolves its own path and would find the real tree. Its
// shared libraries stay where they are (LD_LIBRARY_PATH), so the layout holds
// only what discovery looks at.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell, host-linux, default-sysroot
// RUN: rm -rf %t && mkdir -p %t/bin %t/lib/clang %t/src
// RUN: ln %kairo_bin %t/bin/kairo 2>/dev/null || cp %kairo_bin %t/bin/kairo
// RUN: ln -s %S/../../../Lib/builtin %t/lib/builtin
// RUN: ln -s %S/../../../build/llvm/lib/clang/* %t/lib/clang/
// RUN: ln -s "$(dirname %kairo_bin)/../sysroot" %t/sysroot
// RUN: cp %s %t/src/a.k
// RUN: printf 'import std::io\n\nfn main() -> i32 { return 0 }\n' > %t/src/b.k
// RUN: cd %t/src
//
// std missing: its warning alone; the resource dir, builtin and the sysroot
// were all found.
// RUN: { env LD_LIBRARY_PATH="$(dirname %kairo_bin)/../lib" %t/bin/kairo --error-format=basic --type-check-only a.k 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=NOSTD --implicit-check-not=warning
// NOSTD: warning [P001W]: standard library not found: searched {{.*}}/lib/std
// NOSTD: note [P001N]: pass --std-dir=<dir> naming the standard library tree, or --no-stdlib to build without it
//
// --no-stdlib asked for no std: nothing to warn about.
// RUN: env LD_LIBRARY_PATH="$(dirname %kairo_bin)/../lib" %t/bin/kairo --error-format=basic --type-check-only --no-stdlib a.k 2>&1 \
// RUN:   | %FileCheck %s --check-prefix=QUIET --allow-empty --implicit-check-not=warning
//
// The full layout: no flags, no warnings, and `import std::io` resolves.
// RUN: ln -s %S/../../../Lib/std %t/lib/std
// RUN: env LD_LIBRARY_PATH="$(dirname %kairo_bin)/../lib" %t/bin/kairo --error-format=basic --type-check-only b.k 2>&1 \
// RUN:   | %FileCheck %s --check-prefix=QUIET --allow-empty --implicit-check-not=warning --implicit-check-not=error
//
// No resource dir: its warning alone.
// RUN: rm %t/lib/clang/*
// RUN: { env LD_LIBRARY_PATH="$(dirname %kairo_bin)/../lib" %t/bin/kairo --error-format=basic --type-check-only a.k 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=NORES --implicit-check-not=warning
// NORES: warning [P001W]: clang resource directory not found: searched {{.*}}/lib/clang/<version>/include/stddef.h
// NORES: note [P001N]: pass --resource-dir=<dir> naming the directory whose include/ holds clang's builtin headers (stddef.h)
//
// No sysroot: its warning alone. (The builtin tree's own C++ includes then
// fail to resolve; those errors are not what this checks.)
// RUN: ln -s %S/../../../build/llvm/lib/clang/* %t/lib/clang/
// RUN: rm %t/sysroot
// RUN: { env LD_LIBRARY_PATH="$(dirname %kairo_bin)/../lib" %t/bin/kairo --error-format=basic --type-check-only a.k 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=NOSYS --implicit-check-not=warning
// NOSYS: warning [P001W]: no sysroot found for target '[[T:.+]]': searched {{.*}}/sysroot/[[T]]
// NOSYS: note [P001N]: pass --sysroot=<dir>, or --freestanding to compile without system headers and libraries
//
// --freestanding: no sysroot is what was asked for.
// RUN: { env LD_LIBRARY_PATH="$(dirname %kairo_bin)/../lib" %t/bin/kairo --error-format=basic --type-check-only --freestanding a.k 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=QUIET --allow-empty --implicit-check-not=warning
// QUIET-NOT: P001
