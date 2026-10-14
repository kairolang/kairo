// A --target picks the sysroot bundled beside the compiler,
// <prefix>/sysroot/<dir>, over the --sysroot %kairo always passes. The dir is
// found by target, not by spelling (CompilerInstance::_use_bundled_sysroot):
// vendor, OS version and llvm's aliases do not matter, sub-arch does.
// A malformed match (P007E) is not covered here: it needs a broken directory
// inside the shared bundle.
//
// Each run names a sysroot the bundle must hold (REQUIRES below, one feature
// per shipped SYSROOT.toml); the msvc and Apple lookups live in the sibling
// bundled_sysroot_msvc.k / bundled_sysroot_apple.k, since those sysroots are
// not redistributable and most bundles lack them.
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-linux-gnu
// REQUIRES: sysroot-wasm32-wasi
// REQUIRES: sysroot-armv7-linux-musl
// REQUIRES: sysroot-i686-linux-musl

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// The mingw alias for windows-gnu.
// RUN: { %kairo %s --print-dirs --target=x86_64-w64-mingw32 2>&1 || true; } | %FileCheck %s --check-prefix=MINGW
// MINGW: sysroot: {{.*}}/sysroot/x86_64-windows-gnu (manifest)

// llvm reads gnu-glibc2.31 as a gnu environment.
// RUN: { %kairo %s --print-dirs --target=x86_64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=GLIBC
// GLIBC: sysroot: {{.*}}/sysroot/x86_64-linux-gnu-glibc2.31 (manifest)

// wasi and wasip1 are both WASI preview 1.
// RUN: { %kairo %s --print-dirs --target=wasm32-wasip1 2>&1 || true; } | %FileCheck %s --check-prefix=WASI
// WASI: sysroot: {{.*}}/sysroot/wasm32-wasi (manifest)

// 32-bit ARM Linux is canonicalized to hard-float on both sides.
// RUN: { %kairo %s --print-dirs --target=armv7-unknown-linux-musleabihf 2>&1 || true; } | %FileCheck %s --check-prefix=ARMV7
// ARMV7: sysroot: {{.*}}/sysroot/armv7-linux-musl (manifest)

// -m32 looks up the arch it switches to.
// RUN: { %kairo %s --print-dirs --target=x86_64-linux-musl -m32 2>&1 || true; } | %FileCheck %s --check-prefix=M32
// M32: sysroot: {{.*}}/sysroot/i686-linux-musl (manifest)

// No bundle for the target: --sysroot stays. A second --sysroot replaces
// the one %kairo passes, which may itself live under sysroot/.
// RUN: { %kairo %s --print-dirs --sysroot=%S --target=x86_64-unknown-linux-android 2>&1 || true; } | %FileCheck %s --check-prefix=NONE -DDIR=%S
// RUN: { %kairo %s --print-dirs --sysroot=%S --target=armv7-linux-gnueabi 2>&1 || true; } | %FileCheck %s --check-prefix=NONE -DDIR=%S
// NONE: sysroot: [[DIR]] (prefix)
