// A wasm32-wasi build with --cache-dir compiles and links. The object
// cache's record lives in a section every link leaves out, and wasm has
// none (wasm-ld copies custom sections into the module), so the cache is
// off for wasm: nothing reaches the assembler but the code, and the linked
// module carries no record.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --target=wasm32-wasi --cache-dir=%t.d/cache -o %t.d/a.wasm 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: unknown directive
// CHECK-NOT: error
// RUN: test -s %t.d/a.wasm
// RUN: not grep -c kairo-cache-record %t.d/a.wasm
// A second run over the same cache dir builds the same way.
// RUN: %kairo %s --target=wasm32-wasi --cache-dir=%t.d/cache -o %t.d/b.wasm 2>&1 | %FileCheck %s --allow-empty
// RUN: test -s %t.d/b.wasm
// With -g the compile is the same: no record, no directive error.
// RUN: %kairo %s --target=wasm32-wasi -g --cache-dir=%t.d/cache -o %t.d/g.wasm 2>&1 | %FileCheck %s --allow-empty
// RUN: test -s %t.d/g.wasm
