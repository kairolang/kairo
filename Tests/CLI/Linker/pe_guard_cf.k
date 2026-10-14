// -fguard-cf passes /guard:cf to lld-link (--guard-cf to the MinGW driver);
// -fno-guard-cf passes /guard:no (--no-guard-cf). Unset, nothing is passed.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fguard-cf | %FileCheck %s --check-prefix=MSVCON
// MSVCON: -guard:cf
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fno-guard-cf | %FileCheck %s --check-prefix=MSVCOFF
// MSVCOFF: -guard:no
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fguard-cf | %FileCheck %s --check-prefix=GNUON
// GNUON: --guard-cf{{( |$)}}
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fno-guard-cf | %FileCheck %s --check-prefix=GNUOFF
// GNUOFF: --no-guard-cf
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -guard:
