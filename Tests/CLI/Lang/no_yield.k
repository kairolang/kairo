// --no-yield rejects generators: both the `-> yield T` function and each
// `yield` statement in it. Without the flag the file is accepted.

fn gen() -> yield i32 {
    yield 1
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-yield %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_yield.k:4:{{[0-9]+}}: error [SC001E]: a generator ('-> yield T') is not allowed when yield and async are disabled
// CHECK: no_yield.k:5:{{[0-9]+}}: error [SC001E]: 'yield' is not allowed when yield and async are disabled
