// -fdynamicbase and -fno-dynamicbase pass /dynamicbase and /dynamicbase:no to
// lld-link (--dynamicbase and --disable-dynamicbase to the MinGW driver). Unset,
// the linker default stands.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fdynamicbase | %FileCheck %s --check-prefix=MSVCON
// MSVCON: -dynamicbase{{( |$)}}
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fno-dynamicbase | %FileCheck %s --check-prefix=MSVCOFF
// MSVCOFF: -dynamicbase:no
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fdynamicbase | %FileCheck %s --check-prefix=GNUON
// GNUON: --dynamicbase{{( |$)}}
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fno-dynamicbase | %FileCheck %s --check-prefix=GNUOFF
// GNUOFF: --disable-dynamicbase
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -dynamicbase
