// --wasm-max-memory caps linear memory (--max-memory=<bytes>). It must be a
// multiple of the 65536-byte wasm page; 0 means no cap and passes nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-max-memory=1048576 | %FileCheck %s --check-prefix=MAX
// MAX: --max-memory=1048576
// RUN: { %kairo %s --target=wasm32-wasi --print-ld-args --wasm-max-memory=1000 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: --wasm-max-memory=1000 is not a multiple of the 65536-byte wasm page
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: --max-memory
