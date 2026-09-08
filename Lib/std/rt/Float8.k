/// --- The Kairo Project ------------------------ Lib/std/rt/Float8.k --- ///
///
///   \brief The two OCP FP8 formats as corelib structs: f8e4m3 and f8e5m2.
///
///   \detail
///        LLVM has no IR type at 8 bits of float. Verified against the tree:
///        llvm/IR/Type.h's TypeID enum runs Half, BFloat, Float, Double,
///        X86_FP80, FP128, PPC_FP128 and stops. So these are not builtins with
///        a canonical IR mapping -- they are structs wrapping a u8, and every
///        arithmetic operation promotes to f32, computes, and narrows back.
///        That is exactly what fpext/fptrunc would emit if the type existed, so
///        -O2 folds the round-trip to the same instruction sequence.
///
///        APFloat DOES carry the semantics (semFloat8E4M3FN, semFloat8E5M2),
///        and the constant evaluator uses them directly. This file and APFloat
///        are therefore TWO IMPLEMENTATIONS OF ONE FORMAT. They must agree on
///        all 256 bit patterns in both directions or a value that crosses
///        between compile time and run time changes meaning. See the
///        exhaustive test at the bottom.
///
///   \par Which E4M3
///        E4M3 here is the FINITE-ONLY form (OCP, what every ML toolchain
///        ships): no infinities, max finite 448, NaN is the all-ones
///        significand alone. NOT the IEEE-shaped variant with infinities and a
///        max finite of 240. APFloat spells them semFloat8E4M3FN and
///        semFloat8E4M3; the names differ by two characters and the results
///        differ from every other implementation in existence.
///
///   \par Verified against the C++ port
///        Lib/std/rt/Float8.hh is a 1:1 transcription of this file, and it is
///        what actually runs today -- Stage 1 cannot execute this yet. Both
///        halves passed: exhaustive round-trip over all 256 encodings, and an
///        exhaustive differential against APFloat's semFloat8E4M3FN /
///        semFloat8E5M2 in both directions. A change here that is not mirrored
///        there is untested by construction.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

// === bit-level helpers =====================================================
//
// f32 is IEEE binary32: 1 sign / 8 exponent / 23 mantissa, bias 127. Every
// conversion below goes through its bit pattern rather than through
// arithmetic, because arithmetic would round twice.

/// Reinterpret an f32 as its IEEE bit pattern.
pub fn f32_bits(x: f32) -> u32 {
    return x as u32;                 // TODO(stage1): bit_cast, not numeric.
}

/// Reinterpret an IEEE bit pattern as an f32.
pub fn bits_f32(b: u32) -> f32 {
    return b as f32;                 // TODO(stage1): bit_cast, not numeric.
}

// === f8e4m3 ================================================================

/// \class f8e4m3
/// \brief OCP E4M3, finite-only. 1 sign / 4 exponent / 3 mantissa, bias 7.
///
///        Layout:  S EEEE MMM
///        Max finite:   448.0    (S.1111.110)
///        Min normal:   2^-6     (S.0001.000)
///        Min subnormal: 2^-9    (S.0000.001)
///        NaN:          S.1111.111  -- the ONLY NaN encoding
///        Infinity:     none. Overflow saturates to +/-448.
///
///        Precision, not range. This is the weights-and-activations format.
pub struct f8e4m3 {
    pub var bits: u8 = 0;
}

extend f8e4m3 {
    pub const BIAS:     i32 = 7;
    pub const MANT:     u32 = 3;
    pub const MAX_FIN:  f32 = 448.0;
    pub const NAN_BITS: u8  = 0x7F;

    pub fn f8e4m3(self) { self.bits = 0; }

    pub fn f8e4m3(self, v: f32) { self.bits = f8e4m3::from_f32_bits(v); }

    /// f32 -> E4M3FN, round-to-nearest-even, saturating.
    ///
    /// Saturation rather than infinity is the whole point of the FN form:
    /// there is no inf encoding, so a value past 448 becomes 448, and only
    /// a NaN input produces a NaN output.
    pub fn from_f32_bits(v: f32) -> u8 {
        var w    = f32_bits(v);
        var sign = ((w >> 31) & 1) as u8;
        var exp  = ((w >> 23) & 0xFF) as i32;
        var man  = w & 0x7FFFFF;

        // NaN in, NaN out. Infinity in ALSO becomes NaN: E4M3FN cannot
        // represent inf, and saturating to 448 would silently turn an
        // overflow signal into a finite number.
        if exp == 0xFF { return (sign << 7) | f8e4m3::NAN_BITS; }

        var unb = exp - 127;

        // Above the top finite value -> saturate. The top binade is
        // unb == 8 (e8 == 15), which is VALID -- only 1111.111 is NaN, so
        // the largest finite is 1.75 * 2^8 == 448. Reject only past that.
        if unb > 8 { return (sign << 7) | 0x7E; }
        if (unb == 8) && (man > 0x700000) { return (sign << 7) | 0x7E; }

        // Normal range: unbiased exponent in [-6, 8].
        if unb >= -6 {
            var e8: u32 = (unb + f8e4m3::BIAS) as u32;
            var m8: u32 = man >> 20;              // 23 -> 3 mantissa bits
            var rem: u32 = man & 0xFFFFF;         // the 20 dropped bits
            var halfway: u32 = 0x80000;

            // Round half to even.
            if (rem > halfway) || ((rem == halfway) && ((m8 & 1) == 1)) {
                m8 += 1;
                if m8 == 8 { m8 = 0; e8 += 1; }   // mantissa carried out
            }

            // e8 == 15 is legal; 1111.111 is not. A carry into m8 == 7 at
            // e8 == 15 would land on the NaN encoding, so clamp to 0x7E.
            if (e8 > 15) || ((e8 == 15) && (m8 == 7)) {
                return (sign << 7) | 0x7E;
            }

            return (sign << 7) | ((e8 as u8) << 3) | (m8 as u8);
        }

        // Subnormal range: unbiased exponent in [-9, -7]. The implicit
        // leading 1 becomes explicit and the whole significand shifts right.
        if unb >= -9 {
            var sig: u32  = man | 0x800000;       // restore implicit bit
            var sh:  u32  = (-6 - unb) as u32;    // extra right shift
            var tot: u32  = 20 + sh;
            var m8:  u32  = sig >> tot;
            var rem: u32  = sig & ((1 << tot) - 1);
            var halfway: u32 = 1 << (tot - 1);

            if (rem > halfway) || ((rem == halfway) && ((m8 & 1) == 1)) { m8 += 1; }
            if m8 >= 8 { return (sign << 7) | 0x08; }   // rounded up to normal
            return (sign << 7) | (m8 as u8);
        }

        // Below the smallest subnormal -> signed zero.
        return sign << 7;
    }

    /// E4M3FN -> f32. Always exact: every E4M3 value is representable in
    /// binary32, so no rounding occurs and no mode is needed.
    pub fn to_f32(self) -> f32 {
        var sign: u32 = ((self.bits >> 7) & 1) as u32;
        var e8:   u32 = ((self.bits >> 3) & 0x0F) as u32;
        var m8:   u32 = (self.bits & 0x07) as u32;

        if (e8 == 0x0F) && (m8 == 0x07) {
            return bits_f32((sign << 31) | 0x7FC00000);   // NaN
        }
        if (e8 == 0) && (m8 == 0) {
            return bits_f32(sign << 31);                  // signed zero
        }

        if e8 == 0 {
            // Subnormal: normalize by shifting the leading 1 into place.
            var m = m8;
            var e: i32 = -6;
            while (m & 0x08) == 0 { m = m << 1; e -= 1; }
            m = m & 0x07;
            var e32: u32 = (e + 127) as u32;
            return bits_f32((sign << 31) | (e32 << 23) | (m << 20));
        }

        var e32: u32 = (e8 as i32 - f8e4m3::BIAS + 127) as u32;
        return bits_f32((sign << 31) | (e32 << 23) | (m8 << 20));
    }

    pub fn is_nan(self)  -> bool { return (self.bits & 0x7F) == 0x7F; }
    pub fn is_zero(self) -> bool { return (self.bits & 0x7F) == 0x00; }

    pub fn op as (self) -> f32 { return self.to_f32(); }
}

// === f8e5m2 ================================================================

/// \class f8e5m2
/// \brief OCP E5M2. 1 sign / 5 exponent / 2 mantissa, bias 15. IEEE-shaped:
///        infinities AND NaN both present, unlike E4M3FN.
///
///        Layout:  S EEEEE MM
///        Max finite:   57344.0  (S.11110.11)
///        Min normal:   2^-14
///        Min subnormal: 2^-16
///        Inf:          S.11111.00
///        NaN:          S.11111.xx  with xx != 00
///
///        Range, not precision. The exponent field is IDENTICAL to f16's,
///        which is why f16 <-> e5m2 is a shift rather than a
///        renormalization. This is the gradients format.
pub struct f8e5m2 {
    pub var bits: u8 = 0;
}

extend f8e5m2 {
    pub const BIAS:    i32 = 15;
    pub const MANT:    u32 = 2;
    pub const MAX_FIN: f32 = 57344.0;
    pub const INF_BITS: u8 = 0x7C;

    pub fn f8e5m2(self) { self.bits = 0; }

    pub fn f8e5m2(self, v: f32) { self.bits = f8e5m2::from_f32_bits(v); }

    /// f32 -> E5M2, round-to-nearest-even. Overflow produces INFINITY here,
    /// not saturation -- E5M2 has inf encodings and IEEE semantics.
    pub fn from_f32_bits(v: f32) -> u8 {
        var w    = f32_bits(v);
        var sign = ((w >> 31) & 1) as u8;
        var exp  = ((w >> 23) & 0xFF) as i32;
        var man  = w & 0x7FFFFF;

        if exp == 0xFF {
            if man == 0 { return (sign << 7) | f8e5m2::INF_BITS; }   // inf
            return (sign << 7) | 0x7E;                               // NaN
        }

        var unb = exp - 127;

        if unb > 15 { return (sign << 7) | f8e5m2::INF_BITS; }

        if unb >= -14 {
            var e8: u32 = (unb + f8e5m2::BIAS) as u32;
            var m8: u32 = man >> 21;              // 23 -> 2 mantissa bits
            var rem: u32 = man & 0x1FFFFF;
            var halfway: u32 = 0x100000;

            if (rem > halfway) || ((rem == halfway) && ((m8 & 1) == 1)) {
                m8 += 1;
                if m8 == 4 { m8 = 0; e8 += 1; }
            }
            if e8 >= 31 { return (sign << 7) | f8e5m2::INF_BITS; }
            return (sign << 7) | ((e8 as u8) << 2) | (m8 as u8);
        }

        if unb >= -16 {
            var sig: u32  = man | 0x800000;
            var sh:  u32  = (-14 - unb) as u32;
            var tot: u32  = 21 + sh;
            var m8:  u32  = sig >> tot;
            var rem: u32  = sig & ((1 << tot) - 1);
            var halfway: u32 = 1 << (tot - 1);

            if (rem > halfway) || ((rem == halfway) && ((m8 & 1) == 1)) { m8 += 1; }
            if m8 >= 4 { return (sign << 7) | 0x04; }
            return (sign << 7) | (m8 as u8);
        }

        return sign << 7;
    }

    /// E5M2 -> f32. Always exact.
    pub fn to_f32(self) -> f32 {
        var sign: u32 = ((self.bits >> 7) & 1) as u32;
        var e8:   u32 = ((self.bits >> 2) & 0x1F) as u32;
        var m8:   u32 = (self.bits & 0x03) as u32;

        if e8 == 0x1F {
            if m8 == 0 { return bits_f32((sign << 31) | 0x7F800000); }  // inf
            return bits_f32((sign << 31) | 0x7FC00000);                 // NaN
        }
        if (e8 == 0) && (m8 == 0) { return bits_f32(sign << 31); }

        if e8 == 0 {
            var m = m8;
            var e: i32 = -14;
            while (m & 0x04) == 0 { m = m << 1; e -= 1; }
            m = m & 0x03;
            var e32: u32 = (e + 127) as u32;
            return bits_f32((sign << 31) | (e32 << 23) | (m << 21));
        }

        var e32: u32 = (e8 as i32 - f8e5m2::BIAS + 127) as u32;
        return bits_f32((sign << 31) | (e32 << 23) | (m8 << 21));
    }

    pub fn is_nan(self) -> bool {
        return (((self.bits >> 2) & 0x1F) == 0x1F) && ((self.bits & 0x03) != 0);
    }
    pub fn is_inf(self) -> bool { return (self.bits & 0x7F) == 0x7C; }
    pub fn is_zero(self) -> bool { return (self.bits & 0x7F) == 0x00; }

    pub fn op as (self) -> f32 { return self.to_f32(); }
}

// === arithmetic ============================================================
//
// Every operator promotes to f32, computes, narrows back. The RETURN TYPE IS
// f32, not the fp8 type, and that is deliberate:
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

extend f8e4m3 {
    pub fn op + (self, const rhs: f8e4m3) -> f32 { return self.to_f32() + rhs.to_f32(); }
    pub fn op - (self, const rhs: f8e4m3) -> f32 { return self.to_f32() - rhs.to_f32(); }
    pub fn op * (self, const rhs: f8e4m3) -> f32 { return self.to_f32() * rhs.to_f32(); }
    pub fn op / (self, const rhs: f8e4m3) -> f32 { return self.to_f32() / rhs.to_f32(); }

    /// Bitwise equality, NOT numeric. Two encodings of the same value do not
    /// exist in E4M3FN, so this differs from numeric equality only at NaN
    /// (which compares unequal to itself numerically) and signed zero
    /// (-0.0 == +0.0 numerically, different bits here). Compare through
    /// to_f32() when IEEE comparison semantics are what you want.
    pub fn op == (self, const rhs: f8e4m3) -> bool { return self.bits == rhs.bits; }
}

extend f8e5m2 {
    pub fn op + (self, const rhs: f8e5m2) -> f32 { return self.to_f32() + rhs.to_f32(); }
    pub fn op - (self, const rhs: f8e5m2) -> f32 { return self.to_f32() - rhs.to_f32(); }
    pub fn op * (self, const rhs: f8e5m2) -> f32 { return self.to_f32() * rhs.to_f32(); }
    pub fn op / (self, const rhs: f8e5m2) -> f32 { return self.to_f32() / rhs.to_f32(); }
    pub fn op == (self, const rhs: f8e5m2) -> bool { return self.bits == rhs.bits; }
}

// === round-trip verification ===============================================

/// \brief Every one of the 256 E4M3FN bit patterns survives
///        bits -> f32 -> bits unchanged.
///
///        This is the half of the exhaustive test you can run WITHOUT
///        APFloat. It proves the two conversions are mutual inverses; it
///        does NOT prove either matches the OCP spec. For that, run the
///        same 256 patterns through APFloat's semFloat8E4M3FN in the
///        compiler and diff. Both halves are needed: mutually-inverse
///        conversions can still both be wrong in the same direction.
pub fn verify_e4m3_roundtrip() -> bool {
    for var i: u32 = 0; i < 256; ++i {
        var a = f8e4m3{};
        a.bits = i as u8;
        if a.is_nan() { continue; }          // NaN payload is not preserved
        var back = f8e4m3(a.to_f32());
        if back.bits != a.bits { return false; }
    }
    return true;
}

pub fn verify_e5m2_roundtrip() -> bool {
    for var i: u32 = 0; i < 256; ++i {
        var a = f8e5m2{};
        a.bits = i as u8;
        if a.is_nan() { continue; }
        var back = f8e5m2(a.to_f32());
        if back.bits != a.bits { return false; }
    }
    return true;
}

/// \brief Spot-check the values the OCP spec names explicitly. Cheap, and it
///        catches a bias or shift that is off by one -- which round-trip
///        testing alone cannot, since a consistent off-by-one is still
///        self-inverse.
pub fn verify_e4m3_known() -> bool {
    if f8e4m3(0.0).bits    != 0x00 { return false; }
    if f8e4m3(1.0).bits    != 0x38 { return false; }   // exp 7, mant 0
    if f8e4m3(2.0).bits    != 0x40 { return false; }
    if f8e4m3(448.0).bits  != 0x7E { return false; }   // max finite
    if f8e4m3(1000.0).bits != 0x7E { return false; }   // saturates
    if f8e4m3(-1.0).bits   != 0xB8 { return false; }
    return true;
}

pub fn verify_e5m2_known() -> bool {
    if f8e5m2(0.0).bits     != 0x00 { return false; }
    if f8e5m2(1.0).bits     != 0x3C { return false; }  // exp 15, mant 0
    if f8e5m2(2.0).bits     != 0x40 { return false; }
    if f8e5m2(57344.0).bits != 0x7B { return false; }  // max finite
    if f8e5m2(1.0e30).bits  != 0x7C { return false; }  // overflows to inf
    if f8e5m2(-1.0).bits    != 0xBC { return false; }
    return true;
}