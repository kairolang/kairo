// The primitives' associated constants (primitives.md, Limits): every one is
// a literal before names resolve (Sema/Expand/PrimitiveLimitDesugar.k), so
// it is typed as itself, folds where a literal folds, and costs nothing.
//
// limits_lib.k binds every limit of the integers and of f16/f32/f64/f80 as
// a `pub eval`; host.cc checks each against clang's own macros at compile
// time. The formats clang has no macros for (bf16, f128, the two f8) are
// checked here, against the values in the numeric-limits table, written
// out by hand as literals.
import limits_lib::*

struct <eval N: u32> Width { var n: u32 = N }

fn nan_is_unordered(x: f64) -> bool { return (x != x) && (!(x == x)) && (!(x < x)) }

fn main() -> i32 {
    if !((f8e4m3::MAX as f32) == 448.0f32) { return 1 }
    if !((f8e4m3::MIN as f32) == -448.0f32) { return 2 }
    if !((f8e4m3::MIN_POSITIVE as f32) == 0x1p-6f32) { return 3 }
    if !((f8e4m3::MIN_SUBNORMAL as f32) == 0x1p-9f32) { return 4 }
    if !((f8e4m3::EPSILON as f32) == 0x1p-3f32) { return 5 }
    if !(f8e4m3::MANTISSA_DIGITS == 4u32) { return 6 }
    if !(f8e4m3::DIGITS == 0u32) { return 7 }
    if !(f8e4m3::MAX_DIGITS == 3u32) { return 8 }
    if !(f8e4m3::MIN_EXP == -5) { return 9 }
    if !(f8e4m3::MAX_EXP == 9) { return 10 }
    if !(f8e4m3::MIN_10_EXP == -1) { return 11 }
    if !(f8e4m3::MAX_10_EXP == 2) { return 12 }
    if !(f8e4m3::RADIX == 2u32) { return 13 }
    if !(f8e4m3::BITS == 8u32) { return 14 }
    if !((f8e5m2::MAX as f32) == 57344.0f32) { return 15 }
    if !((f8e5m2::MIN as f32) == -57344.0f32) { return 16 }
    if !((f8e5m2::MIN_POSITIVE as f32) == 0x1p-14f32) { return 17 }
    if !((f8e5m2::MIN_SUBNORMAL as f32) == 0x1p-16f32) { return 18 }
    if !((f8e5m2::EPSILON as f32) == 0x1p-2f32) { return 19 }
    if !(f8e5m2::MANTISSA_DIGITS == 3u32) { return 20 }
    if !(f8e5m2::DIGITS == 0u32) { return 21 }
    if !(f8e5m2::MAX_DIGITS == 2u32) { return 22 }
    if !(f8e5m2::MIN_EXP == -13) { return 23 }
    if !(f8e5m2::MAX_EXP == 16) { return 24 }
    if !(f8e5m2::MIN_10_EXP == -4) { return 25 }
    if !(f8e5m2::MAX_10_EXP == 4) { return 26 }
    if !(f8e5m2::RADIX == 2u32) { return 27 }
    if !(f8e5m2::BITS == 8u32) { return 28 }
    if !((f8e5m2::INFINITY as f32) > (f8e5m2::MAX as f32)) { return 29 }
    if !((f8e5m2::NEG_INFINITY as f32) < (f8e5m2::MIN as f32)) { return 30 }
    if !((bf16::MAX as f32) == 0x1.fep+127f32) { return 31 }
    if !((bf16::MIN as f32) == -0x1.fep+127f32) { return 32 }
    if !((bf16::MIN_POSITIVE as f32) == 0x1p-126f32) { return 33 }
    if !((bf16::MIN_SUBNORMAL as f32) == 0x1p-133f32) { return 34 }
    if !((bf16::EPSILON as f32) == 0x1p-7f32) { return 35 }
    if !(bf16::MANTISSA_DIGITS == 8u32) { return 36 }
    if !(bf16::DIGITS == 2u32) { return 37 }
    if !(bf16::MAX_DIGITS == 4u32) { return 38 }
    if !(bf16::MIN_EXP == -125) { return 39 }
    if !(bf16::MAX_EXP == 128) { return 40 }
    if !(bf16::MIN_10_EXP == -37) { return 41 }
    if !(bf16::MAX_10_EXP == 38) { return 42 }
    if !(bf16::RADIX == 2u32) { return 43 }
    if !(bf16::BITS == 16u32) { return 44 }
    if !((bf16::INFINITY as f32) > (bf16::MAX as f32)) { return 45 }
    if !((bf16::NEG_INFINITY as f32) < (bf16::MIN as f32)) { return 46 }
    if !(f128::MAX == 0x1.ffffffffffffffffffffffffffffp+16383f128) { return 47 }
    if !(f128::MIN == -0x1.ffffffffffffffffffffffffffffp+16383f128) { return 48 }
    if !(f128::MIN_POSITIVE == 0x1p-16382f128) { return 49 }
    if !(f128::MIN_SUBNORMAL == 0x1p-16494f128) { return 50 }
    if !(f128::EPSILON == 0x1p-112f128) { return 51 }
    if !(f128::MANTISSA_DIGITS == 113u32) { return 52 }
    if !(f128::DIGITS == 33u32) { return 53 }
    if !(f128::MAX_DIGITS == 36u32) { return 54 }
    if !(f128::MIN_EXP == -16381) { return 55 }
    if !(f128::MAX_EXP == 16384) { return 56 }
    if !(f128::MIN_10_EXP == -4931) { return 57 }
    if !(f128::MAX_10_EXP == 4932) { return 58 }
    if !(f128::RADIX == 2u32) { return 59 }
    if !(f128::BITS == 128u32) { return 60 }
    if !(f128::INFINITY > f128::MAX) { return 61 }
    if !(f128::NEG_INFINITY < f128::MIN) { return 62 }

    // A NaN equals nothing, itself included: `x == f64::NAN` is always
    // false, so a NaN test is `x != x`.
    var n = f64::NAN
    if !nan_is_unordered(n) { return 200 }
    if n == f64::NAN { return 201 }
    var q = f8e4m3::NAN as f32
    if q == q { return 202 }
    // An infinity is an ordinary value to compare with.
    if !(1.0 / 0.0 == f64::INFINITY) { return 203 }

    // Typed as itself in any context, and wrapping like any value of it.
    var m = u8::MAX
    m += 1
    if m != 0 { return 204 }
    var lo = i32::MIN
    lo -= 1
    if lo != i32::MAX { return 205 }
    if (i64::MIN as i128) != -9223372036854775808i128 { return 206 }
    if (u128::MAX >> 64) != (u64::MAX as u128) { return 207 }

    // Constant wherever a constant is needed: an array length, `eval if`.
    var buf: [u8; u16::MAX as usize + 1]
    buf[65535] = 7
    if buf[65535] != 7 { return 209 }
    eval if (i8::MAX as i32) + 1 == 128 { } else { return 210 }
    if (U64_MAX != u64::MAX) || (F32_MAX != f32::MAX) { return 211 }
    // A generic value argument, which parses as a type: `Width<8>`.
    var w = Width<u8::BITS>{}
    if w.n != 8 { return 212 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The literals the pass mints: typed as their limit's type, a negative one
// under its `-`, and no chain left.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid {{[0-9]+}}: {{.*}}use.k
// SEMA-NOT:   ChainExpr {{.*}}::MAX
// SEMA:       FloatingLiteralExpr {{.*}}: f128
// SEMA:       IntegerLiteralExpr {{.*}}: u32

// Exact hex floats and clang's infinity and NaN, at each type's precision.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}use.k
// IR-DAG: 0x1.ffffffffffffffffffffffffffffp+16383Q
// IR-DAG: static_cast<__bf16>(0x1.fep+127f)
// IR-DAG: __builtin_nan("")
// IR-DAG: (- 9223372036854775807LL - 1)

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/c
// RUN: %t.exe

// The integers and the C++-native floats, through the header kcc builds
// from limits_lib.k: each equals clang's own macro, at compile time.
// REQUIRES: kcc
// RUN: cd %S && %kcc -c host.cc -o %t.d/host.o
// RUN: %kcc %t.d/host.o -o %t.d/app && %t.d/app; test $? -eq 42
