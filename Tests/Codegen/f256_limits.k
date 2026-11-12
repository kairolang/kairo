// f256 / f512 associated constants and the methods of an f256 / f512
// value (the generated `extend f256` / `extend f512` in num/f256_t.k,
// f512_t.k). The float-valued limits are the classes' statics, printed here
// as their encodings: the expected bits are IEEE's (binary256: 1/19/236,
// bias 262143; f512: 1/23/488, bias 4194303), computed independently. The
// counts and exponents are PrimitiveLimits.k's, computed from FloatLayout as
// every other float's are, and agree with floor/ceil of (p - 1) log10(2) etc.
// taken exactly.

import std::io

fn b256(x: f256) -> u256 {
    return __builtin_bitcast<u256, f256>(x)
}

fn b512(x: f512) -> u512 {
    return __builtin_bitcast<u512, f512>(x)
}

fn main() -> i32 {
    io::println(f"MAX {b256(f256::MAX):x}")
    io::println(f"MIN {b256(f256::MIN):x}")
    io::println(f"EPSILON {b256(f256::EPSILON):x}")
    io::println(f"MIN_POSITIVE {b256(f256::MIN_POSITIVE):x}")
    io::println(f"MIN_SUBNORMAL {b256(f256::MIN_SUBNORMAL):x}")
    io::println(f"INFINITY {b256(f256::INFINITY):x}")
    io::println(f"NEG_INFINITY {b256(f256::NEG_INFINITY):x}")
    io::println(f"NAN {b256(f256::NAN):x}")
    io::println(f"MAX text {f256::MAX}")
    io::println(
        f"BITS {f256::BITS} MANTISSA_DIGITS {f256::MANTISSA_DIGITS} DIGITS {f256::DIGITS} MAX_DIGITS {f256::MAX_DIGITS}",
    )

    io::println(
        f"MIN_EXP {f256::MIN_EXP} MAX_EXP {f256::MAX_EXP} MIN_10_EXP {f256::MIN_10_EXP} MAX_10_EXP {f256::MAX_10_EXP} RADIX {f256::RADIX}",
    )

    io::println(f"512 MAX {b512(f512::MAX):x}")
    io::println(f"512 MIN {b512(f512::MIN):x}")
    io::println(f"512 EPSILON {b512(f512::EPSILON):x}")
    io::println(f"512 MIN_POSITIVE {b512(f512::MIN_POSITIVE):x}")
    io::println(f"512 NAN {b512(f512::NAN):x}")
    io::println(f"512 NEG_INFINITY {b512(f512::NEG_INFINITY):x}")
    io::println(
        f"512 BITS {f512::BITS} MANTISSA_DIGITS {f512::MANTISSA_DIGITS} DIGITS {f512::DIGITS} MAX_DIGITS {f512::MAX_DIGITS}",
    )

    io::println(
        f"512 MIN_EXP {f512::MIN_EXP} MAX_EXP {f512::MAX_EXP} MIN_10_EXP {f512::MIN_10_EXP} MAX_10_EXP {f512::MAX_10_EXP}",
    )

    // The limits are values of the type: they compare and compute as any.
    var one: f256 = 1.0
    var next      = one + f256::EPSILON
    io::println(f"next {next > one} {(next - one) == f256::EPSILON} {f256::MAX < f256::INFINITY}")

    // Methods on a value.
    var two: f256 = 2.0
    var neg: f256 = -9.0
    io::println(f"sqrt2 {two.sqrt()}")
    io::println(f"sqrt4 {(two * two).sqrt()} abs {neg.abs()} copysign {two.copysign(neg)}")
    io::println(f"fma {two.fma(two, one)} bits {one.to_bits():x}")
    // A limit is bound first: `f256::NAN.is_nan()` is not a limit then a
    // call for any primitive yet (f64's neither).
    var nan  = f256::NAN
    var inf  = f256::INFINITY
    var tiny = f256::MIN_SUBNORMAL
    io::println(
        f"nan {nan.is_nan()} {one.is_nan()} inf {inf.is_infinite()} finite {one.is_finite()} {nan.is_finite()}",
    )

    io::println(
        f"zero {(one - one).is_zero()} sub {tiny.is_subnormal()} normal {one.is_normal()} {tiny.is_normal()}",
    )

    io::println(
        f"neg {neg.is_sign_negative()} {one.is_sign_negative()} unordered {one.is_unordered(nan)} {one.is_unordered(two)}",
    )

    var t5: f512 = 2.0
    var n5       = f512::NAN
    io::println(f"512 sqrt2 {t5.sqrt()} nan {n5.is_nan()} bits {(t5 / t5).to_bits():x}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: MAX 7fffefffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
// CHECK-NEXT: MIN ffffefffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
// CHECK-NEXT: EPSILON 3ff1300000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: MIN_POSITIVE 100000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: MIN_SUBNORMAL 1
// CHECK-NEXT: INFINITY 7ffff00000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: NEG_INFINITY fffff00000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: NAN 7ffff80000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: MAX text 1.61132571748576047361957211845200501064402387454966951747637125049607183e+78913
// CHECK-NEXT: BITS 256 MANTISSA_DIGITS 237 DIGITS 71 MAX_DIGITS 73
// CHECK-NEXT: MIN_EXP -262141 MAX_EXP 262144 MIN_10_EXP -78912 MAX_10_EXP 78913 RADIX 2
// CHECK-NEXT: 512 MAX 7ffffeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
// CHECK-NEXT: 512 MIN fffffeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
// CHECK-NEXT: 512 EPSILON 3ffe1700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: 512 MIN_POSITIVE 100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: 512 NAN 7fffff80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: 512 NEG_INFINITY ffffff00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: 512 BITS 512 MANTISSA_DIGITS 489 DIGITS 146 MAX_DIGITS 149
// CHECK-NEXT: 512 MIN_EXP -4194301 MAX_EXP 4194304 MIN_10_EXP -1262610 MAX_10_EXP 1262611
// CHECK-NEXT: next true true true
// CHECK-NEXT: sqrt2 1.4142135623730950488016887242096980785696718753769480731766797379{{[0-9]+$}}
// CHECK-NEXT: sqrt4 2 abs 9 copysign -2
// CHECK-NEXT: fma 5 bits 3ffff00000000000000000000000000000000000000000000000000000000000
// CHECK-NEXT: nan true false inf true finite true false
// CHECK-NEXT: zero true sub true normal true false
// CHECK-NEXT: neg true false unordered true false
// CHECK-NEXT: 512 sqrt2 1.4142135623730950488016887242096980785696718753769480731766797379907324784621070388503875343276415727350138462309122970249248360558507372126{{[0-9]+}} nan true bits 3fffff00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
