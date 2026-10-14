// --ios-version-min only means something for an iOS target. On a macOS target
// it must not change the deployment target; the link says it was ignored.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: { %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --ios-version-min=17.0 2>&1 || true; } | %FileCheck %s --check-prefix=WARN
// WARN: warning [L001W]: --ios-version-min only applies to iOS targets
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --ios-version-min=17.0 | %FileCheck %s --check-prefix=LINE
// LINE: -platform_version macos 14.0
