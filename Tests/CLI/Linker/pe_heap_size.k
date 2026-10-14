// --heap-size sets the PE heap reserve in bytes: /heap: for lld-link, --heap=
// for the MinGW driver. 0 leaves the linker default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --heap-size=2097152 | %FileCheck %s --check-prefix=MSVC
// MSVC: -heap:2097152
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --heap-size=2097152 | %FileCheck %s --check-prefix=GNU
// GNU: --heap=2097152
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -heap:
