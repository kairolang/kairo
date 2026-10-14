// --stack-size sets the PE stack reserve in bytes: /stack: for lld-link,
// --stack= for the MinGW driver. 0 leaves the linker default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --stack-size=1048576 | %FileCheck %s --check-prefix=MSVC
// MSVC: -stack:1048576
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --stack-size=1048576 | %FileCheck %s --check-prefix=GNU
// GNU: --stack=1048576
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -stack:
