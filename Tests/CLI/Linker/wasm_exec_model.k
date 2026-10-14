// --wasm-exec-model=reactor links a module with no _start: wasm-ld gets
// --no-entry and the command crt is not linked. The default, command, keeps
// the command crt and an entry. Other values are rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-exec-model=reactor | %FileCheck %s --check-prefix=REACTOR
// REACTOR: --no-entry
// REACTOR-NOT: crt1-command.o
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=CMD
// CMD: crt1
// CMD-NOT: --no-entry
// RUN: { %kairo %s --target=wasm32-wasi --print-ld-args --wasm-exec-model=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: unknown --wasm-exec-model bogus
