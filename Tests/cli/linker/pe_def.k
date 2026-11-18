// --def supplies a module-definition file. lld-link takes it as /def:; the
// MinGW driver has no such option and reads a .def given as an input.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --def=exports.def | %FileCheck %s --check-prefix=MSVC
// MSVC: -def:exports.def
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --def=exports.def | %FileCheck %s --check-prefix=GNU
// GNU: exports.def
