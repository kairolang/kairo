//===--- Float8.hh - OCP FP8 formats as structs -----------------*- C++ -*-===//
//
//   1:1 port of Lib/std/rt/Float8.k for testing under Stage 0.
//
//   LLVM has no IR type at 8 bits of float: llvm/IR/Type.h's TypeID enum runs
//   Half, BFloat, Float, Double, X86_FP80, FP128, PPC_FP128 and stops. So
//   these are structs wrapping a uint8_t, and every arithmetic operation
//   promotes to float, computes, and narrows back -- exactly what
//   fpext/fptrunc would emit if the type existed, so -O2 folds the round-trip
//   to the same instruction sequence.
//
//   APFloat DOES carry the semantics (semFloat8E4M3FN, semFloat8E5M2). This
//   file and APFloat are TWO IMPLEMENTATIONS OF ONE FORMAT and must agree on
//   all 256 bit patterns in both directions, or a value that crosses between
//   compile time and run time changes meaning.
//
//   E4M3 here is the FINITE-ONLY form (OCP): no infinities, max finite 448,
//   NaN is the all-ones significand alone. NOT the IEEE-shaped variant with
//   infinities and max finite 240. APFloat spells them semFloat8E4M3FN and
//   semFloat8E4M3.
//
//   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
//   Copyright (c) 2026 Dhruvan Kartik
//
//===----------------------------------------------------------------------===//

#pragma once

#include <cstdint>
#include <cstring>

namespace kairo::rt {

// === bit-level helpers =====================================================
//
// float is IEEE binary32: 1 sign / 8 exponent / 23 mantissa, bias 127. Every
// conversion below goes through the bit pattern rather than through
// arithmetic, because arithmetic would round twice.
//
// memcpy, not a union or a reinterpret_cast: it is the only strictly
// conforming spelling, and every compiler folds it to a register move.

inline std::uint32_t f32_bits(float x) {
    std::uint32_t b;
    std::memcpy(&b, &x, 4);
    return b;
}

inline float bits_f32(std::uint32_t b) {
    float x;
    std::memcpy(&x, &b, 4);
    return x;
}

// === f8e4m3 ================================================================
//
// OCP E4M3, finite-only. 1 sign / 4 exponent / 3 mantissa, bias 7.
//
//   Layout:        S EEEE MMM
//   Max finite:    448.0     (S.1111.110)
//   Min normal:    2^-6      (S.0001.000)
//   Min subnormal: 2^-9      (S.0000.001)
//   NaN:           S.1111.111  -- the ONLY NaN encoding
//   Infinity:      none. Overflow saturates to +/-448.
//
// Precision, not range. The weights-and-activations format.

struct f8e4m3 {
    std::uint8_t bits = 0;

    static constexpr std::int32_t  BIAS     = 7;
    static constexpr std::uint32_t MANT     = 3;
    static constexpr float         MAX_FIN  = 448.0f;
    static constexpr std::uint8_t  NAN_BITS = 0x7F;

    f8e4m3() : bits(0) {}
    explicit f8e4m3(float v) : bits(from_f32_bits(v)) {}

    /// float -> E4M3FN, round-to-nearest-even, saturating.
    ///
    /// Saturation rather than infinity is the whole point of the FN form:
    /// there is no inf encoding, so a value past 448 becomes 448, and only a
    /// NaN input produces a NaN output.
    static std::uint8_t from_f32_bits(float v) {
        std::uint32_t w    = f32_bits(v);
        std::uint8_t  sign = static_cast<std::uint8_t>((w >> 31) & 1u);
        std::int32_t  exp  = static_cast<std::int32_t>((w >> 23) & 0xFFu);
        std::uint32_t man  = w & 0x7FFFFFu;

        // NaN in, NaN out. Infinity in ALSO becomes NaN: E4M3FN cannot
        // represent inf, and saturating to 448 would silently turn an
        // overflow signal into a finite number.
        if (exp == 0xFF) {
            return static_cast<std::uint8_t>((sign << 7) | NAN_BITS);
        }

        std::int32_t unb = exp - 127;

        // Above the top finite value -> saturate. The top binade is
        // unb == 8 (e8 == 15), which is VALID -- only 1111.111 is NaN, so
        // the largest finite is 1.75 * 2^8 == 448. Reject only past that.
        if (unb > 8) {
            return static_cast<std::uint8_t>((sign << 7) | 0x7E);
        }
        if (unb == 8 && man > 0x700000u) {   // > 1.875 * 2^8, rounds past 448
            return static_cast<std::uint8_t>((sign << 7) | 0x7E);
        }

        // Normal range: unbiased exponent in [-6, 8].
        if (unb >= -6) {
            std::uint32_t e8   = static_cast<std::uint32_t>(unb + BIAS);
            std::uint32_t m8   = man >> 20;          // 23 -> 3 mantissa bits
            std::uint32_t rem  = man & 0xFFFFFu;     // the 20 dropped bits
            std::uint32_t half = 0x80000u;

            // Round half to even.
            if (rem > half || (rem == half && (m8 & 1u) == 1u)) {
                m8 += 1;
                if (m8 == 8) { m8 = 0; e8 += 1; }    // mantissa carried out
            }
            if (e8 > 15 || (e8 == 15 && m8 == 7)) {
                return static_cast<std::uint8_t>((sign << 7) | 0x7E);
            }
            return static_cast<std::uint8_t>(
                (sign << 7) | (static_cast<std::uint8_t>(e8) << 3)
                            | static_cast<std::uint8_t>(m8));
        }

        // Subnormal range: unbiased exponent in [-9, -7]. The implicit
        // leading 1 becomes explicit and the whole significand shifts right.
        if (unb >= -9) {
            std::uint32_t sig  = man | 0x800000u;    // restore implicit bit
            std::uint32_t sh   = static_cast<std::uint32_t>(-6 - unb);
            std::uint32_t tot  = 20 + sh;
            std::uint32_t m8   = sig >> tot;
            std::uint32_t rem  = sig & ((1u << tot) - 1u);
            std::uint32_t half = 1u << (tot - 1);

            if (rem > half || (rem == half && (m8 & 1u) == 1u)) { m8 += 1; }
            if (m8 >= 8) {                           // rounded up to normal
                return static_cast<std::uint8_t>((sign << 7) | 0x08);
            }
            return static_cast<std::uint8_t>((sign << 7)
                                             | static_cast<std::uint8_t>(m8));
        }

        // Below the smallest subnormal -> signed zero.
        return static_cast<std::uint8_t>(sign << 7);
    }

    /// E4M3FN -> float. Always exact: every E4M3 value is representable in
    /// binary32, so no rounding occurs and no mode is needed.
    float to_f32() const {
        std::uint32_t sign = static_cast<std::uint32_t>((bits >> 7) & 1);
        std::uint32_t e8   = static_cast<std::uint32_t>((bits >> 3) & 0x0F);
        std::uint32_t m8   = static_cast<std::uint32_t>(bits & 0x07);

        if (e8 == 0x0F && m8 == 0x07) {
            return bits_f32((sign << 31) | 0x7FC00000u);   // NaN
        }
        if (e8 == 0 && m8 == 0) {
            return bits_f32(sign << 31);                   // signed zero
        }

        if (e8 == 0) {
            // Subnormal: normalize by shifting the leading 1 into place.
            std::uint32_t m = m8;
            std::int32_t  e = -6;
            while ((m & 0x08u) == 0) { m <<= 1; e -= 1; }
            m &= 0x07u;
            std::uint32_t e32 = static_cast<std::uint32_t>(e + 127);
            return bits_f32((sign << 31) | (e32 << 23) | (m << 20));
        }

        std::uint32_t e32 =
            static_cast<std::uint32_t>(static_cast<std::int32_t>(e8) - BIAS + 127);
        return bits_f32((sign << 31) | (e32 << 23) | (m8 << 20));
    }

    bool is_nan()  const { return (bits & 0x7F) == 0x7F; }
    bool is_zero() const { return (bits & 0x7F) == 0x00; }

    explicit operator float() const { return to_f32(); }
};

// === f8e5m2 ================================================================
//
// OCP E5M2. 1 sign / 5 exponent / 2 mantissa, bias 15. IEEE-shaped:
// infinities AND NaN both present, unlike E4M3FN.
//
//   Layout:        S EEEEE MM
//   Max finite:    57344.0   (S.11110.11)
//   Min normal:    2^-14
//   Min subnormal: 2^-16
//   Inf:           S.11111.00
//   NaN:           S.11111.xx  with xx != 00
//
// Range, not precision. The exponent field is IDENTICAL to f16's, which is
// why f16 <-> e5m2 is a shift rather than a renormalization. The gradients
// format.

struct f8e5m2 {
    std::uint8_t bits = 0;

    static constexpr std::int32_t  BIAS     = 15;
    static constexpr std::uint32_t MANT     = 2;
    static constexpr float         MAX_FIN  = 57344.0f;
    static constexpr std::uint8_t  INF_BITS = 0x7C;

    f8e5m2() : bits(0) {}
    explicit f8e5m2(float v) : bits(from_f32_bits(v)) {}

    /// float -> E5M2, round-to-nearest-even. Overflow produces INFINITY
    /// here, not saturation -- E5M2 has inf encodings and IEEE semantics.
    static std::uint8_t from_f32_bits(float v) {
        std::uint32_t w    = f32_bits(v);
        std::uint8_t  sign = static_cast<std::uint8_t>((w >> 31) & 1u);
        std::int32_t  exp  = static_cast<std::int32_t>((w >> 23) & 0xFFu);
        std::uint32_t man  = w & 0x7FFFFFu;

        if (exp == 0xFF) {
            if (man == 0) {
                return static_cast<std::uint8_t>((sign << 7) | INF_BITS);
            }
            return static_cast<std::uint8_t>((sign << 7) | 0x7E);       // NaN
        }

        std::int32_t unb = exp - 127;

        if (unb > 15) {
            return static_cast<std::uint8_t>((sign << 7) | INF_BITS);
        }

        if (unb >= -14) {
            std::uint32_t e8   = static_cast<std::uint32_t>(unb + BIAS);
            std::uint32_t m8   = man >> 21;          // 23 -> 2 mantissa bits
            std::uint32_t rem  = man & 0x1FFFFFu;
            std::uint32_t half = 0x100000u;

            if (rem > half || (rem == half && (m8 & 1u) == 1u)) {
                m8 += 1;
                if (m8 == 4) { m8 = 0; e8 += 1; }
            }
            if (e8 >= 31) {
                return static_cast<std::uint8_t>((sign << 7) | INF_BITS);
            }
            return static_cast<std::uint8_t>(
                (sign << 7) | (static_cast<std::uint8_t>(e8) << 2)
                            | static_cast<std::uint8_t>(m8));
        }

        if (unb >= -16) {
            std::uint32_t sig  = man | 0x800000u;
            std::uint32_t sh   = static_cast<std::uint32_t>(-14 - unb);
            std::uint32_t tot  = 21 + sh;
            std::uint32_t m8   = sig >> tot;
            std::uint32_t rem  = sig & ((1u << tot) - 1u);
            std::uint32_t half = 1u << (tot - 1);

            if (rem > half || (rem == half && (m8 & 1u) == 1u)) { m8 += 1; }
            if (m8 >= 4) {
                return static_cast<std::uint8_t>((sign << 7) | 0x04);
            }
            return static_cast<std::uint8_t>((sign << 7)
                                             | static_cast<std::uint8_t>(m8));
        }

        return static_cast<std::uint8_t>(sign << 7);
    }

    /// E5M2 -> float. Always exact.
    float to_f32() const {
        std::uint32_t sign = static_cast<std::uint32_t>((bits >> 7) & 1);
        std::uint32_t e8   = static_cast<std::uint32_t>((bits >> 2) & 0x1F);
        std::uint32_t m8   = static_cast<std::uint32_t>(bits & 0x03);

        if (e8 == 0x1F) {
            if (m8 == 0) { return bits_f32((sign << 31) | 0x7F800000u); }  // inf
            return bits_f32((sign << 31) | 0x7FC00000u);                   // NaN
        }
        if (e8 == 0 && m8 == 0) { return bits_f32(sign << 31); }

        if (e8 == 0) {
            std::uint32_t m = m8;
            std::int32_t  e = -14;
            while ((m & 0x04u) == 0) { m <<= 1; e -= 1; }
            m &= 0x03u;
            std::uint32_t e32 = static_cast<std::uint32_t>(e + 127);
            return bits_f32((sign << 31) | (e32 << 23) | (m << 21));
        }

        std::uint32_t e32 =
            static_cast<std::uint32_t>(static_cast<std::int32_t>(e8) - BIAS + 127);
        return bits_f32((sign << 31) | (e32 << 23) | (m8 << 21));
    }

    bool is_nan() const {
        return ((bits >> 2) & 0x1F) == 0x1F && (bits & 0x03) != 0;
    }
    bool is_inf()  const { return (bits & 0x7F) == 0x7C; }
    bool is_zero() const { return (bits & 0x7F) == 0x00; }

    explicit operator float() const { return to_f32(); }
};

// === arithmetic ============================================================
//
// Every operator promotes to float, computes, narrows back. The RETURN TYPE
// IS float, not the fp8 type, and that is deliberate:
//
//   - it is what actually happens; hiding it invites double-rounding bugs
//   - accumulate-in-higher-precision becomes the default rather than
//     something the user has to remember
//   - a chain a*b + c*d rounds ONCE, at the final assignment, instead of
//     four times
//
// The cost: fp8 does not satisfy a `T op T -> T` numeric bound, so generic
// code written against one will not accept it. That is the honest outcome --
// fp8 is a storage format, and code that treats it as a general arithmetic
// type is code that will lose precision.

inline float operator+(f8e4m3 a, f8e4m3 b) { return a.to_f32() + b.to_f32(); }
inline float operator-(f8e4m3 a, f8e4m3 b) { return a.to_f32() - b.to_f32(); }
inline float operator*(f8e4m3 a, f8e4m3 b) { return a.to_f32() * b.to_f32(); }
inline float operator/(f8e4m3 a, f8e4m3 b) { return a.to_f32() / b.to_f32(); }

/// Bitwise equality, NOT numeric. Two encodings of the same value do not
/// exist in E4M3FN, so this differs from numeric equality only at NaN (which
/// compares unequal to itself numerically) and signed zero (-0.0 == +0.0
/// numerically, different bits here). Compare through to_f32() when IEEE
/// comparison semantics are what you want.
inline bool operator==(f8e4m3 a, f8e4m3 b) { return a.bits == b.bits; }
inline bool operator!=(f8e4m3 a, f8e4m3 b) { return a.bits != b.bits; }

inline float operator+(f8e5m2 a, f8e5m2 b) { return a.to_f32() + b.to_f32(); }
inline float operator-(f8e5m2 a, f8e5m2 b) { return a.to_f32() - b.to_f32(); }
inline float operator*(f8e5m2 a, f8e5m2 b) { return a.to_f32() * b.to_f32(); }
inline float operator/(f8e5m2 a, f8e5m2 b) { return a.to_f32() / b.to_f32(); }
inline bool  operator==(f8e5m2 a, f8e5m2 b) { return a.bits == b.bits; }
inline bool  operator!=(f8e5m2 a, f8e5m2 b) { return a.bits != b.bits; }

// === round-trip verification ===============================================

/// Every one of the 256 E4M3FN bit patterns survives bits -> float -> bits
/// unchanged.
///
/// This is the half of the exhaustive test you can run WITHOUT APFloat. It
/// proves the two conversions are mutual inverses; it does NOT prove either
/// matches the OCP spec. For that, run the same 256 patterns through
/// APFloat's semFloat8E4M3FN and diff. Both halves are needed:
/// mutually-inverse conversions can still both be wrong in the same
/// direction.
inline bool verify_e4m3_roundtrip() {
    for (std::uint32_t i = 0; i < 256; ++i) {
        f8e4m3 a;
        a.bits = static_cast<std::uint8_t>(i);
        if (a.is_nan()) { continue; }        // NaN payload is not preserved
        f8e4m3 back(a.to_f32());
        if (back.bits != a.bits) { return false; }
    }
    return true;
}

inline bool verify_e5m2_roundtrip() {
    for (std::uint32_t i = 0; i < 256; ++i) {
        f8e5m2 a;
        a.bits = static_cast<std::uint8_t>(i);
        if (a.is_nan()) { continue; }
        f8e5m2 back(a.to_f32());
        if (back.bits != a.bits) { return false; }
    }
    return true;
}

/// Spot-check the values the OCP spec names explicitly. Cheap, and it catches
/// a bias or shift that is off by one -- which round-trip testing alone
/// cannot, since a consistent off-by-one is still self-inverse.
inline bool verify_e4m3_known() {
    if (f8e4m3(0.0f).bits    != 0x00) { return false; }
    if (f8e4m3(1.0f).bits    != 0x38) { return false; }   // exp 7, mant 0
    if (f8e4m3(2.0f).bits    != 0x40) { return false; }
    if (f8e4m3(448.0f).bits  != 0x7E) { return false; }   // max finite
    if (f8e4m3(1000.0f).bits != 0x7E) { return false; }   // saturates
    if (f8e4m3(-1.0f).bits   != 0xB8) { return false; }
    return true;
}

inline bool verify_e5m2_known() {
    if (f8e5m2(0.0f).bits     != 0x00) { return false; }
    if (f8e5m2(1.0f).bits     != 0x3C) { return false; }  // exp 15, mant 0
    if (f8e5m2(2.0f).bits     != 0x40) { return false; }
    if (f8e5m2(57344.0f).bits != 0x7B) { return false; }  // max finite
    if (f8e5m2(1.0e30f).bits  != 0x7C) { return false; }  // overflows to inf
    if (f8e5m2(-1.0f).bits    != 0xBC) { return false; }
    return true;
}

} // namespace kairo::rt