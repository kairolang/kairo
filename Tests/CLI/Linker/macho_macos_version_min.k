// --macos-version-min sets the deployment target in -platform_version. It beats
// MACOSX_DEPLOYMENT_TARGET and the version in the triple, so a build script can
// pin it whatever the environment says. A malformed version is rejected here
// instead of reaching ld64.lld, whose message does not name the flag.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args | %FileCheck %s --check-prefix=TRIPLE
// TRIPLE: -platform_version macos 14.0
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --macos-version-min=13.0 | %FileCheck %s --check-prefix=FLAG
// FLAG: -platform_version macos 13.0
// RUN: { %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --macos-version-min=banana 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: --macos-version-min=banana: expected a version
