// --wasm-import-memory makes the module import its linear memory
// (--import-memory) instead of defining it. Unset, no memory option is passed.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-import-memory | %FileCheck %s --check-prefix=ON
// ON: --import-memory
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: --import-memory
