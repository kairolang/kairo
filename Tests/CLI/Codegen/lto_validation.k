// --lto takes off, thin or full and rejects anything else. The value has no
// effect yet: the in-process backend always emits a native object, so there is no
// bitcode for the linker to optimize.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --lto=thin || true; } | %FileCheck %s --check-prefix=OKN
// OKN-NOT: -flto
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --lto=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--lto'; accepted: off, thin, full
