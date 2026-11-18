// -fwasm-threads links with shared memory (--shared-memory). The matching
// +atomics target feature is the compile side and is not covered here.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args -fwasm-threads | %FileCheck %s --check-prefix=ON
// ON: --shared-memory
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: --shared-memory
