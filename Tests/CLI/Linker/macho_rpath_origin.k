// --rpath-origin adds an -rpath anchored at @loader_path or @executable_path,
// with an optional subpath. @rpath is refused: -rpath entries are searched
// through it, so an rpath that is itself @rpath/... can never resolve.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --rpath-origin=@loader_path/../lib | %FileCheck %s --check-prefix=LP
// LP: -rpath @loader_path/../lib
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --rpath-origin=@executable_path | %FileCheck %s --check-prefix=EP
// EP: -rpath @executable_path
// RUN: { %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --rpath-origin=@rpath 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: --rpath-origin=@rpath: expected @loader_path or @executable_path
