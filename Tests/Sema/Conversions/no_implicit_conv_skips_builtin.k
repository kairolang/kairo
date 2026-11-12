// `-fno-implicit-conv` holds the user's files to explicit casts, but not
// Lib/builtin: the library is written against the default lattice, and its
// errors (base/intrinsics.k __builtin_memset, fmt/fmt_buf.k, base/hash.k)
// used to print under the user's flag and spend the 20-error cap (P780).
// The user's own widening is still an error.
// RUN: { %kairo %s --type-check-only -fno-implicit-conv 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: no_implicit_conv_skips_builtin.k:[[@LINE+5]]:{{[0-9]+}}: error [SC028E]

fn widen(x: i64) -> i64 { return x }
fn main() -> i32 {
    const a: i32 = 1
    const b: i64 = a
    return widen(b) as i32
}
