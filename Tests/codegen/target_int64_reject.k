// Only the 64-bit integers follow the target's int64_t spelling. i16, i32
// and u32 keep `short` and `int` on every target, LP64 and LLP64 alike.

fn f(a: i32, b: u32, c: i16, d: i64) -> i32 { return a }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-gnu
// REQUIRES: sysroot-x86_64-windows-gnu
// RUN: { %kairo %s --target=x86_64-linux-gnu --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LP64
// RUN: { %kairo %s --target=x86_64-w64-mingw32 --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LLP64
// LP64: signed int f(signed int a, unsigned int b, signed short c, signed long d) noexcept;
// LLP64: signed int f(signed int a, unsigned int b, signed short c, signed long long d) noexcept;
