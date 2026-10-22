// --rpath is dropped on a static link (musl here is static-only): there is no
// dynamic section to carry it. The drop is reported.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: { %kairo %s --target=x86_64-linux-musl --print-ld-args --rpath=/opt/lib 2>&1 || true; } | %FileCheck %s --check-prefix=WARN
// WARN: warning [L001W]: --rpath has no effect on a static link
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --rpath=/opt/lib | %FileCheck %s --check-prefix=DROP
// DROP-NOT: -rpath /opt/lib
