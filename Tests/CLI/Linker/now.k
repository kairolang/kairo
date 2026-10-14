// --now requests eager (immediate) symbol binding: the link line gets `-z now`.
// Observed through --print-ld-args so no binary is produced.
// REQUIRES: bundled-sysroot

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --target=x86_64-linux-musl --now --print-ld-args | %FileCheck %s
// CHECK: ld.lld
// CHECK-SAME: -z now
