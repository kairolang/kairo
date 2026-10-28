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
// (one lit feature per shipped SYSROOT.toml); this file is the msvc
// spelling of target_int64.k, apart because that sysroot is not
// redistributable.
// REQUIRES: sysroot-x86_64-windows-msvc
// LLP64 spells `long long`, and never a bare `long`.
// RUN: { %kairo %s --target=x86_64-pc-windows-msvc --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=LLONG
// LLONG-NOT: signed long x
// LLONG: signed long long exp {
// LLONG: signed long long f(signed long long x, unsigned long long y) noexcept;
// LLONG-NOT: signed long x
