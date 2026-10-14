// -fnxcompat and -fno-nxcompat pass /nxcompat and /nxcompat:no to lld-link
// (--nxcompat and --disable-nxcompat to the MinGW driver). Unset, the linker
// default stands.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fnxcompat | %FileCheck %s --check-prefix=MSVCON
// MSVCON: -nxcompat{{( |$)}}
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fno-nxcompat | %FileCheck %s --check-prefix=MSVCOFF
// MSVCOFF: -nxcompat:no
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fnxcompat | %FileCheck %s --check-prefix=GNUON
// GNUON: --nxcompat{{( |$)}}
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fno-nxcompat | %FileCheck %s --check-prefix=GNUOFF
// GNUOFF: --disable-nxcompat
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -nxcompat
