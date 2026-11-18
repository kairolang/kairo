// --manifest-file embeds the named manifest instead of the default. lld only
// accepts a manifest input together with /manifest:embed, so naming a file
// implies embedding.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// RUN: %kairo %s --target=x86_64-pc-windows-msvc --print-ld-args --manifest-file=app.manifest | %FileCheck %s --check-prefix=MSVC
// MSVC: -manifest:embed
// MSVC: -manifestinput:app.manifest
// RUN: %kairo %s --target=x86_64-w64-mingw32 --print-ld-args --manifest-file=app.manifest | %FileCheck %s --check-prefix=GNU
// GNU: -Xlink=-manifest:embed
// GNU: -Xlink=-manifestinput:app.manifest
