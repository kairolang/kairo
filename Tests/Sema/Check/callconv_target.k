// LLVM implements the calling conventions on x86-64 and AArch64 only;
// anywhere else clang would drop the attribute with a warning, so Kairo
// makes it an error (SC137E) rather than change what callers assume.

@preserve_most
priv fn slow(n: usize) -> usize { return n }

@preserve_all
priv fn slow_fp(x: f64) -> f64 { return x }

@preserve_none
priv fn dispatch(n: usize) -> usize { return n }

fn main() -> i32 { return (slow(0) + dispatch(0)) as i32 + slow_fp(0.0) as i32 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=riscv64-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=RV
// RV-DAG: callconv_target.k:6:{{[0-9]+}}: error [SC137E]: '@preserve_most' is not available on riscv64-{{.*}}linux-gnu
// RV-DAG: callconv_target.k:9:{{[0-9]+}}: error [SC137E]: '@preserve_all' is not available on riscv64-{{.*}}linux-gnu
// RV-DAG: callconv_target.k:12:{{[0-9]+}}: error [SC137E]: '@preserve_none' is not available on riscv64-{{.*}}linux-gnu

// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// RUN: { %kairo %s --type-check-only --target=aarch64-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: {{error|warning}}
