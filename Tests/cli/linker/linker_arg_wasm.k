// --linker-arg reaches wasm-ld too: --import-undefined leaves a body-less
// `ffi "c"` function as a module import for the host to supply, where it
// would otherwise be an undefined symbol.

ffi "c" fn host_log(v: i32)

fn main() -> i32 {
    host_log(7)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: %kairo %s --target=wasm32-wasi --print-ld-args --linker-arg=--import-undefined | %FileCheck %s --check-prefix=ARGS
// ARGS: wasm-ld {{.*}}--import-undefined
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s --target=wasm32-wasi -o %t.d/no.wasm 2>&1 || true; } | %FileCheck %s --check-prefix=UNDEF
// UNDEF: host_log
// RUN: %kairo %s --target=wasm32-wasi -o %t.d/a.wasm --linker-arg=--import-undefined
// RUN: test -s %t.d/a.wasm
