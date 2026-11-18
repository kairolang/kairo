// The msvc half of bundled_sysroot.k: exact name, then another vendor.
// Apart because the msvc sysroot is not redistributable and most bundles
// lack it.
// REQUIRES: sysroot-x86_64-windows-msvc

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-dirs --target=x86_64-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// RUN: { %kairo %s --print-dirs --target=x86_64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// MSVC: sysroot: {{.*}}/sysroot/x86_64-windows-msvc (manifest)
