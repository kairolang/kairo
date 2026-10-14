// --wasm-export exports a symbol from the module (wasm-ld --export=<sym>), once
// per occurrence and in order.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-export=foo --wasm-export=bar | %FileCheck %s --check-prefix=EXP
// EXP: --export=foo
// EXP: --export=bar
