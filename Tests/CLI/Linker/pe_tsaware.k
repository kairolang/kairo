// -ftsaware and -fno-tsaware pass /tsaware and /tsaware:no to lld-link
// (--tsaware and --disable-tsaware to the MinGW driver). Unset, the linker
// default stands.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -ftsaware | %FileCheck %s --check-prefix=MSVCON
// MSVCON: -tsaware{{( |$)}}
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fno-tsaware | %FileCheck %s --check-prefix=MSVCOFF
// MSVCOFF: -tsaware:no
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -ftsaware | %FileCheck %s --check-prefix=GNUON
// GNUON: --tsaware{{( |$)}}
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fno-tsaware | %FileCheck %s --check-prefix=GNUOFF
// GNUOFF: --disable-tsaware
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -tsaware
