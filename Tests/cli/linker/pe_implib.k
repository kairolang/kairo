// --implib names the import library written beside a DLL: /implib: for lld-link,
// --out-implib= for the MinGW driver.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --shared --implib=foo.lib | %FileCheck %s --check-prefix=MSVC
// MSVC: -implib:foo.lib
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --shared --implib=foo.lib | %FileCheck %s --check-prefix=GNU
// GNU: --out-implib=foo.lib
