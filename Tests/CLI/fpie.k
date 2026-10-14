// -fpie turns the default static musl link into a static-PIE one (-pie, no
// dynamic linker, rcrt1.o instead of crt1.o). It is consumed by the linker
// only; the default link must stay non-PIE.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -fpie | %FileCheck %s --check-prefix=PIE
// PIE: -static -pie --no-dynamic-linker
// PIE: rcrt1.o
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=DEF
// DEF-NOT: -pie
// DEF-NOT: --no-dynamic-linker
// DEF: crt1.o
