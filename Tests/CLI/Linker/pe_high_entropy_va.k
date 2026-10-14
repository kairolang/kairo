// -fhigh-entropy-va and -fno-high-entropy-va pass /highentropyva and
// /highentropyva:no to lld-link (--high-entropy-va and --disable-high-entropy-va
// to the MinGW driver). Unset, the linker default stands.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fhigh-entropy-va | %FileCheck %s --check-prefix=MSVCON
// MSVCON: -highentropyva{{( |$)}}
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args -fno-high-entropy-va | %FileCheck %s --check-prefix=MSVCOFF
// MSVCOFF: -highentropyva:no
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fhigh-entropy-va | %FileCheck %s --check-prefix=GNUON
// GNUON: --high-entropy-va{{( |$)}}
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args -fno-high-entropy-va | %FileCheck %s --check-prefix=GNUOFF
// GNUOFF: --disable-high-entropy-va
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -highentropyva
