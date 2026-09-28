// i64/u64 spell the target's int64_t. `long` is 64 bits only on LP64; on
// LLP64 (Windows) and every 32-bit target it is 32 bits and int64_t is
// `long long`. A hardcoded `long` made every i64 a 32-bit type there and
// every i64 parameter disagree with every header's int64_t. BigFloat's
// exponent is a builtin i64 and follows the same spelling.

fn f(x: i64, y: u64) -> i64 { return x }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// LP64 targets keep `long`.
// RUN: { %kairo %s --target=x86_64-linux-gnu --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LP64
// RUN: { %kairo %s --target=aarch64-linux-gnu --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LP64
// LP64: signed long exp;
// LP64: signed long f(signed long x, unsigned long y);
// LP64-NOT: long long

// LLP64 and 32-bit targets spell `long long`, and never a bare `long`.
// RUN: { %kairo %s --target=x86_64-pc-windows-msvc --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LLONG
// RUN: { %kairo %s --target=i686-linux-gnu --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LLONG
// LLONG: signed long long exp;
// LLONG: signed long long f(signed long long x, unsigned long long y);
// LLONG-NOT: signed long x
