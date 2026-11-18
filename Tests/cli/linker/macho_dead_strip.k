// -fdead-strip is the Mach-O spelling of dead stripping (-dead_strip) and
// -fgc-sections maps to it as well. An explicit -fno-dead-strip wins over
// -fgc-sections.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args -fdead-strip | %FileCheck %s --check-prefix=ON
// ON: -dead_strip
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args -fgc-sections | %FileCheck %s --check-prefix=GC
// GC: -dead_strip
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args -fgc-sections -fno-dead-strip | %FileCheck %s --check-prefix=OFF
// OFF-NOT: -dead_strip
