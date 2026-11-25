// A WebAssembly target with no operating system has no C library, which the
// runtime is built on: it is refused before anything is built, with the target
// to use instead, however the triple is spelled.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --target=wasm32-unknown-unknown --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --target=wasm32 -o %t.wasm 2>&1 || true; } | %FileCheck %s --check-prefix=SHORT
// RUN: { %kairo %s --target=wasm32-unknown-none --freestanding -c -o %t.o 2>&1 || true; } | %FileCheck %s --check-prefix=NONE
// RUN: { %kairo %s --target=wasm64-unknown-unknown --print-ld-args 2>&1 || true; } | %FileCheck %s --check-prefix=W64
// CHECK: error [P011E]: target 'wasm32-unknown-unknown' is not supported: a WebAssembly target with no operating system has no C library, which Kairo's runtime needs
// CHECK-NEXT: note [P011N]: build for --target=wasm32-wasi
// CHECK-NOT: P008W
// CHECK-NOT: error
// SHORT: error [P011E]: target 'wasm32{{[-a-z]*}}' is not supported
// NONE: error [P011E]: target 'wasm32-unknown-none' is not supported
// W64: error [P011E]: target 'wasm64-unknown-unknown' is not supported
