// Clang builtins through the whole pipeline: emitted bare, so the C++
// compiler gives each its own meaning. `__builtin_trap` is noreturn, so
// `main` needs no `return`, and the program must die by a signal (SIGILL on
// x86, SIGTRAP on aarch64), not exit.

fn main() -> i32 {
    var a = __builtin_popcount(0xF0 as u32);
    var p = __builtin_alloca(64);
    __builtin_trap();
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -ge 128
