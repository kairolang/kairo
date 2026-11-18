// --pdb names the PDB file: /pdb: for lld-link, --pdb= for the MinGW driver.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --pdb=out.pdb | %FileCheck %s --check-prefix=MSVC
// MSVC: -pdb:out.pdb
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --pdb=out.pdb | %FileCheck %s --check-prefix=GNU
// GNU: --pdb=out.pdb
