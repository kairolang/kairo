// --manifest embeds a default application manifest (/manifest:embed). The MinGW
// driver has no manifest option, so lld-link's is handed through with -Xlink.
// Unset, no manifest option is passed.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --manifest | %FileCheck %s --check-prefix=MSVC
// MSVC: -manifest:embed
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --manifest | %FileCheck %s --check-prefix=GNU
// GNU: -Xlink=-manifest:embed
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -manifest
