// A wasm32-wasi build is warning-free. Two sources of noise used to fire on
// every compile:
//  - `#pragma float_control` around each ffi header region: clang ignores
//    it on a target without strict-FP support and says so (C459W, once per
//    region, 23 per TU with the prelude). It is now written only where the
//    target honours it; the contraction pragma alone restores C++'s state.
//  - clang 22 deprecates the `wasm32-wasi` triple for `wasm32-wasip1`.
//    `--target=wasm32-wasi` stays the user's spelling (and the sysroot's
//    name); only what reaches clang says wasip1.

ffi "c" import "math.h"

fn main() -> i32 {
    var x: f64 = 2.25
    return sqrt(x) as i32 - 1
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --target=wasm32-wasi -o %t.d/a.wasm 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: warning
// RUN: test -s %t.d/a.wasm
// RUN: %kairo %s --target=wasm32-wasi --print-clang-args | %FileCheck %s --check-prefix=TRIPLE
// TRIPLE: -triple wasm32-{{(unknown-)?}}wasip1
