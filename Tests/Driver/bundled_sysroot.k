// A --target picks the sysroot bundled beside the compiler,
// <prefix>/sysroot/<dir>, over the --sysroot %kairo always passes. The dir is
// found by target, not by spelling (CompilerInstance::_use_bundled_sysroot):
// vendor, OS version and llvm's aliases do not matter, sub-arch does.
// A malformed match (P007E) is not covered here: it needs a broken directory
// inside the shared bundle.
//
// REQUIRES: bundled-sysroot

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// Exact name.
// RUN: { %kairo %s --print-dirs --target=x86_64-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// Another vendor, and the mingw alias for windows-gnu.
// RUN: { %kairo %s --print-dirs --target=x86_64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// RUN: { %kairo %s --print-dirs --target=x86_64-w64-mingw32 2>&1 || true; } | %FileCheck %s --check-prefix=MINGW
// MSVC: sysroot: {{.*}}/sysroot/x86_64-windows-msvc (manifest)
// MINGW: sysroot: {{.*}}/sysroot/x86_64-windows-gnu (manifest)

// llvm reads gnu-glibc2.31 as a gnu environment.
// RUN: { %kairo %s --print-dirs --target=x86_64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=GLIBC
// GLIBC: sysroot: {{.*}}/sysroot/x86_64-linux-gnu-glibc2.31 (manifest)

// darwin is macosx and aarch64 is arm64; arm64e is its own sub-arch.
// RUN: { %kairo %s --print-dirs --target=aarch64-apple-darwin23.1.0 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64
// RUN: { %kairo %s --print-dirs --target=arm64e-apple-macosx14.0 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64E
// ARM64: sysroot: {{.*}}/sysroot/arm64-apple-macosx (manifest)
// ARM64E: sysroot: {{.*}}/sysroot/arm64e-apple-macosx (manifest)

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
