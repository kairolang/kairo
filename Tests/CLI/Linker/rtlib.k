// --rtlib picks the runtime library the linker uses: compiler-rt (default)
// links clang_rt builtins, libgcc swaps them for -lgcc, anything else is a
// linker error rather than a silent fallback.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: { %kairo %s --target=x86_64-linux-musl --print-ld-args --rtlib=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [L001E]: unknown --rtlib value bogus; expected compiler-rt or libgcc

// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --rtlib=libgcc | %FileCheck %s --check-prefix=GCC
// GCC:     -lgcc
// GCC-NOT: libclang_rt.builtins.a

// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --rtlib=compiler-rt | %FileCheck %s --check-prefix=CRT
// CRT: libclang_rt.builtins.a
