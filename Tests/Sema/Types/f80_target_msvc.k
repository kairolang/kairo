// The Windows half of f80_target.k (which says why f80 is a per-ABI fact).
// Apart because the msvc sysroots are not redistributable: both runs need
// their target's headers, so the file is UNSUPPORTED where the bundle lacks
// them rather than failing on an unrelated header error.
// REQUIRES: sysroot-x86_64-windows-msvc
// REQUIRES: sysroot-aarch64-windows-msvc
// RUN: { %kairo %s --type-check-only --target=aarch64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=ARMWIN
// RUN: { %kairo %s --type-check-only --target=x86_64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC

fn main() -> i32 {
    var x: f80 = 1.0;
    return 0;
}

// Windows on ARM: `long double` is binary64.
// ARMWIN: error [P003E]: 'f80' requires x87, which aarch64 does not have
// ARMWIN: note [I900N]: use 'f64' (what C's 'long double' is on this target)

// x87 hardware, binary64 ABI: the has-x87 wording, and the format named.
// MSVC: error [P003E]: 'f80' is unavailable on 'x86_64-pc-windows-msvc': x87 exists but this ABI's 'long double' is binary64
// MSVC: note [I900N]: use 'f64' (what C's 'long double' is on this target)
