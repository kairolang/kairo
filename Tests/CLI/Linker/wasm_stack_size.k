// --wasm-stack-size sets the shadow stack (-z stack-size=<bytes>), passed only
// when given. The size must be 16-byte aligned.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --wasm-stack-size=131072 | %FileCheck %s --check-prefix=STK
// STK: -z stack-size=131072
// RUN: { %kairo %s --target=wasm32-wasi --print-ld-args --wasm-stack-size=4097 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: --wasm-stack-size=4097 is not 16-byte aligned
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args | %FileCheck %s --check-prefix=NONE
// NONE-NOT: stack-size
