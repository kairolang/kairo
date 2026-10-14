// --wasm-export-memory exports the module's linear memory (--export-memory).
// Unset, no memory option is passed.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-export-memory | %FileCheck %s --check-prefix=ON
// ON: --export-memory
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: --export-memory
