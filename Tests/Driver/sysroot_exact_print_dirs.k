// --print-dirs and --print-clang-args name the sysroot a compile would use:
// with --sysroot-exact that is the directory as given, never a bundled root
// for the same target.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot, host-linux, host-x86_64
// RUN: { %kairo %s --print-dirs --target=x86_64-linux-gnu --sysroot=%t.nonexistent --sysroot-exact 2>&1 || true; } | %FileCheck %s --check-prefix=DIRS
// RUN: %kairo %s --print-clang-args --target=x86_64-linux-gnu --sysroot=%t.nonexistent --sysroot-exact | %FileCheck %s --check-prefix=ARGS
// DIRS: sysroot:{{ +}}{{.*}}sysroot_exact_print_dirs.k.tmp.nonexistent
// ARGS: -isysroot {{.*}}sysroot_exact_print_dirs.k.tmp.nonexistent
