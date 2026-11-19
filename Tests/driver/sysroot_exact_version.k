// --version names the sysroot a compile would use: with --sysroot-exact that
// is the directory as given, never a bundled root for the same target.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot, host-linux, host-x86_64
// RUN: %kairo %s --version --target=x86_64-linux-gnu --sysroot=%t.nonexistent --sysroot-exact | %FileCheck %s
// CHECK: sysroot:{{ +}}{{.*}}sysroot_exact_version.k.tmp.nonexistent
