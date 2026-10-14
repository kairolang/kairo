// --shared on the bundled musl sysroot is an error: that sysroot is static-only.
// The message says so and points at --target as the way out.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: { %kairo %s --target=x86_64-linux-musl --print-ld-args --shared 2>&1 || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error [L001E]: cannot build a shared library: the sysroot {{.*}} is static-only
// ERR: pass --target for a dynamic target
