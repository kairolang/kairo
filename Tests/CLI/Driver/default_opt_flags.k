// Optimizations clang leaves off by default that cannot change what a
// correct program does: speculative devirtualization and forced vtable
// emission (C++ only, above -O0). Not constructor aliases: they stopped the
// base-object constructor of a Kairo template inlining (ClangBackend.k).

fn main() -> i32 { return 0 }

// RUN: %kairo %s -O2 --print-clang-args 2>&1 | %FileCheck %s --check-prefix=O2
// O2: -fdevirtualize-speculatively
// O2: -fforce-emit-vtables
// O2-NOT: -mconstructor-aliases

// RUN: %kairo %s -O0 --print-clang-args 2>&1 | %FileCheck %s --check-prefix=O0
// O0-NOT: -fdevirtualize-speculatively
// O0-NOT: -fforce-emit-vtables

// RUN: %kairo %s -O2 --target=aarch64-apple-macosx14.0 --print-clang-args 2>&1 | %FileCheck %s --check-prefix=APPLE
// APPLE: -fdevirtualize-speculatively
