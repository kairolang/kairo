// --macos-sdk names the SDK directly: it becomes -syslibroot and beats --sysroot
// and the bundled sysroot. The fixture next to this file is a minimal SDK (a
// usr/lib and an SDKSettings.json). A path that is not an SDK is an error.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --macos-sdk=%S/fake_sdk | %FileCheck %s --check-prefix=SDK
// SDK: -syslibroot {{.*}}/fake_sdk
// RUN: { %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --macos-sdk=%S/no_such_sdk 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: the SDK {{.*}}/no_such_sdk does not exist
