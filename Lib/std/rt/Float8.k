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
            if (rem > halfwa
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
    if f8e4m3(0.0).bits    != 0x00 { return fa