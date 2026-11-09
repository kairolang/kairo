// An optimised wasm32-wasi build links: identical code folding is on by default for
// optimised builds, but wasm-ld has none, so the default skips wasm targets. Asking for
// it explicitly still gets the wasm flavor's error.

import std::io

fn main() -> i32 {
    io::println("hi")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.wasm
// RUN: %kairo --target wasm32-wasi -O2 %s -o %t.wasm
// RUN: test -s %t.wasm
// RUN: { %kairo --target wasm32-wasi -O2 --icf %s -o %t.icf.wasm 2>&1 || true; } | %FileCheck %s --check-prefix=EXPLICIT
// EXPLICIT: wasm-ld does not implement identical code folding
