// --wasm-initial-memory sets the initial linear memory (--initial-memory=<bytes>)
// and is passed only when given: the registry default of one page is not a
// request, and forcing it would make any module with data fail to link.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-initial-memory=131072 | %FileCheck %s --check-prefix=INIT
// INIT: --initial-memory=131072
// RUN: { %kairo %s --target=wasm32-wasi --print-ld-args --wasm-initial-memory=100000 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: --wasm-initial-memory=100000 is not a multiple of the 65536-byte wasm page
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: --initial-memory
