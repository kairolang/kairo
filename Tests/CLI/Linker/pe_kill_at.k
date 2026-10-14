// --kill-at strips the @n stdcall suffix from exported names: /kill-at for
// lld-link, --kill-at for the MinGW driver.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --kill-at | %FileCheck %s --check-prefix=MSVC
// MSVC: -kill-at
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --kill-at | %FileCheck %s --check-prefix=GNU
// GNU: --kill-at
