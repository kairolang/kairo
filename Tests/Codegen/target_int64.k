// i64/u64 spell the target's int64_t, which is not decided by the data
// model alone. LP64 Linux uses `long`. LLP64 (Windows), every 32-bit
// target, and Darwin (LP64, but int64_t is `long long`) use `long long`.
// A mismatch makes every i64 parameter disagree with every header's
// int64_t: wrong width on LLP64 and 32-bit, wrong mangling on Darwin.
// BigFloat's exponent is a builtin i64 and follows the same spelling.

fn f(x: i64, y: u64) -> i64 { return x }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// Every cross target needs its own C library headers: lib/builtin's runtime
// header includes <stdint.h>, and a host libc read for another target makes
// uint64_t 32 bits on Windows. Each triple below names a bundled sysroot
// (one lit feature per shipped SYSROOT.toml). The msvc and Darwin spellings
// are in target_int64_msvc.k / target_int64_apple.k: those sysroots are not
// redistributable, so most bundles lack them.
// REQUIRES: sysroot-x86_64-linux-gnu
// REQUIRES: sysroot-aarch64-linux-musl
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-i686-linux-musl
// LP64 targets keep `long`.
// RUN: { %kairo %s --target=x86_64-linux-gnu --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LP64
// RUN: { %kairo %s --target=aarch64-linux-musl --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LP64
// LP64: signed long exp;
// LP64: signed long f(signed long x, unsigned long y);
// LP64-NOT: long long

// LLP64 and 32-bit targets spell `long long`, and never a bare `long`.
// RUN: { %kairo %s --target=x86_64-w64-mingw32 --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LLONG
// RUN: { %kairo %s --target=i686-linux-musl --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LLONG
// LLONG-NOT: signed long x
// LLONG: signed long long exp;
// LLONG: signed long long f(signed long long x, unsigned long long y);
// LLONG-NOT: signed long x
