// --subsystem sets the PE subsystem (/subsystem: for lld-link, --subsystem= for
// the MinGW driver). Unset, nothing is passed and lld infers it from
// main/WinMain. Values lld does not know are rejected here.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --subsystem=windows | %FileCheck %s --check-prefix=MSVC
// MSVC: -subsystem:windows
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --subsystem=windows | %FileCheck %s --check-prefix=GNU
// GNU: --subsystem=windows
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -subsystem
// RUN: { %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --subsystem=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: unknown --subsystem bogus
