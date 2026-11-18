// The Apple half of bundled_sysroot.k: darwin is macosx and aarch64 is
// arm64; arm64e is its own sub-arch. Apart because Apple SDKs are not
// redistributable and most bundles lack them.
// REQUIRES: sysroot-arm64-macosx
// REQUIRES: sysroot-arm64e-macosx

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-dirs --target=aarch64-apple-darwin23.1.0 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64
// RUN: { %kairo %s --print-dirs --target=arm64e-apple-macosx14.0 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64E
// ARM64: sysroot: {{.*}}/sysroot/arm64-apple-macosx (manifest)
// ARM64E: sysroot: {{.*}}/sysroot/arm64e-apple-macosx (manifest)
