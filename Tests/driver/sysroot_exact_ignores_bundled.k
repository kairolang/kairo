// With an explicit --target an explicit --sysroot loses to the bundled sysroot, unless
// --sysroot-exact is also given: then the named directory is the root, never
// replaced by a bundled one (a build of a new libc root compiles against its
// own headers). The missing directory below shows which root was picked:
// the exact run reports it, the plain run is silent because the bundled root
// stands in for it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot, host-linux, host-x86_64
// RUN: { %kairo --target=x86_64-linux-gnu --sysroot=%t.nonexistent --sysroot-exact --no-stdlib --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=EXACT
// RUN: { %kairo --target=x86_64-linux-gnu --sysroot=%t.nonexistent --no-stdlib --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=BUNDLED --allow-empty
// EXACT: warning [P008W]: sysroot not found: {{.*}}sysroot_exact_ignores_bundled.k.tmp.nonexistent is not a directory
// BUNDLED-NOT: sysroot not found
