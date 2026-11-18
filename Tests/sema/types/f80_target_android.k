// The Android case of f80_target.k (which says why f80 is a per-ABI fact):
// x87 hardware, binary128 ABI. Apart because it needs the NDK's headers,
// which the bundle may not ship.
// REQUIRES: sysroot-x86_64-linux-android
// RUN: { %kairo %s --type-check-only --target=x86_64-unknown-linux-android 2>&1 || true; } | %FileCheck %s --check-prefix=ANDROID

fn main() -> i32 {
    var x: f80 = 1.0;
    return 0;
}

// ANDROID: error [P003E]: 'f80' is unavailable on 'x86_64-unknown-linux-android': x87 exists but this ABI's 'long double' is binary128
