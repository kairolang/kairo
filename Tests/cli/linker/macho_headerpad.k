// --headerpad is a byte count; ld64.lld reads -headerpad as hex, so 1024 bytes
// is passed as 400. Left at 0 the flag is absent and the linker default stands.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --headerpad=1024 | %FileCheck %s --check-prefix=HP
// HP: -headerpad 400
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -headerpad
