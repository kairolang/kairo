// --compress-debug=<v> adds --compress-debug-sections=<v> to the ELF link
// line; the default adds nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --compress-debug=zstd | %FileCheck %s --check-prefix=ZSTD
// ZSTD: --compress-debug-sections=zstd
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=DEF
// DEF-NOT: compress-debug-sections
