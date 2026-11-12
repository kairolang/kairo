/// --- The Kairo Project -------------------------- Lib/std/rt/Float8.k --- ///
///
///   \brief The two OCP FP8 formats as classes: F8E4M3 and F8E5M2, what C++
///          spells `f8e4m3` and `f8e5m2`.
///
///   \detail
///        LLVM has no IR type at 8 bits of float (llvm/IR/Type.h's TypeID
///        runs Half, BFloat, Float, Double, X86_FP80, FP128, PPC_FP128 and
///        stops), so Sema types `f8e4m3` / `f8e5m2` as builtins and C++
///        spells each as a class wrapping its byte, as f256 is spelled
///        F256 (Compiler/AST/Node/CanonicalNodes.k). The compiler loads this
///        file only into the files that spell one of the two types
///        (DepScanner's f8 users, Preprocessor::_add_wide_floats), and binds
///        the classes as lang items (NameResolution), so `a + b`, `x as
///        f32`, `x as f8e4m3` and `f"{x}"` on a builtin f8 value are calls of
///        the members below in the generated C++.
///
///        Every conversion INTO a format rounds once, to nearest even:
///        from a float through its bits (never through arithmetic, which
///        would round twice), an f128's significand cut to 64 bits with
///        the rest kept as a sticky bit. An integer converts through f64,
///        exact wherever the result is finite. Every conversion OUT is
///        exact into f32, and so into every wider float.
///
///        Arithmetic computes in f32 and rounds the result once to the
///        format: f32's 24 bits are at least 2p + 2 for both formats' p
///        (4, 3), so the f32 rounding of + - * / is innocuous and the
///        result is the correctly rounded one.
///
///        APFloat carries the same semantics (semFloat8E4M3FN,
///        semFloat8E5M2), and the compiler uses it for literals
///        (Native/KShims.hh, f8_literal_bits): the two implementations must
///        agree on all 256 encodings in both directions, which
///        F8E4M3::verify_ / F8E5M2::verify_ check (Tests/Codegen/types).
///
///   \par Which E4M3
///        E4M3 here is the FINITE-ONLY form (OCP, what every ML toolchain
///        ships): no infinities, max finite 448, NaN is the all-ones
///        significand alone; a value past 448 saturates to +/-448, and an
///        infinity in becomes NaN. NOT the IEEE-shaped variant with
///        infinities and a max finite of 240. APFloat spells them
///        semFloat8E4M3FN and semFloat8E4M3.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "rt/fmt.h"

import fmt::fmt_buf::FmtBuf

// === the two formats, as parameters =========================================
//
// A format is (mant, bias, fn): mantissa bits, exponent bias, and whether it
// is the finite-only form (no infinity; all ones is NaN only with an all-ones
// mantissa). E4M3FN is (3, 7, true), E5M2 is (2, 15, false). The exponent
// field is 7 - mant bits wide.

/// The encoding nearest `sig * 2^(e - 63)` (the value's leading bit at bit
/// 63 of `sig`, `sticky` set when nonzero bits lie below it), with sign `neg`,
/// rounded to nearest even. Overflow saturates (fn) or is an infinity.
priv fn f8_encode_(neg: bool, e: i32, sig: u64, sticky: bool, mant: u32, bias: i32, fnz: bool) -> u8 {
    var s: u8   = if (neg) => (0x80) else => 0
    var emin    = 1 - bias
    var field   = 0
    var shift   = 0
    if e >= emin {
        field = e + bias
        shift = 63 - (mant as i32)
    } else {
        shift = 63 - (mant as i32) + (emin - e)
    }

    // Too large to need its bits: the overflow test below decides.
    if field > 64 {
        field = 64
    }

    var q: u64 = 0
    var up     = false
    if shift >= 66 {
        up = false // below half the smallest subnormal: zero.
    } else if shift == 65 || shift == 64 {
        // Every bit of sig is dropped: half is 2^(shift-1), which sig's
        // leading bit reaches only at shift 64.
        if shift == 64 {
            var half: u64 = 1 << 63
            var rest      = sig & (half - 1)
            up = (rest != 0) || sticky // above half; exactly half ties to even (q = 0).
        }
    } else {
        var sh   = shift as u64
        var half = (1 as u64) << (sh - 1)
        q = sig >> sh
        var rem = sig & ((half << 1) - 1)
        if rem > half || (rem == half && sticky) {
            up = true
        } else if rem == half && (q & 1) == 1 {
            up = true
        }
    }

    if up {
        q += 1
    }

    var top: u64 = (1 as u64) << (mant as u64)
    if field > 0 {
        if q == (top << 1) {
            q = q >> 1
            field += 1
        }
    } else if q == top {
        field = 1 // a subnormal rounded up to the smallest normal.
    }

    var m = (q & (top - 1)) as u8
    var emax_field: i32 = ((1 as i32) << ((7 - mant) as i32)) - 1
    if fnz {
        if field > emax_field || (field == emax_field && (m as u64) == top - 1) {
            return s | ((((emax_field as u64) << (mant as u64)) | (top - 2)) as u8)
        }
    } else if field >= emax_field {
        return s | (((emax_field as u64) << (mant as u64)) as u8)
    }

    return s | ((((field as u64) << (mant as u64)) as u8) | m)
}

/// The encoding of NaN with sign `neg`: all ones (fn), or the quiet NaN
/// with the top mantissa bit set.
priv fn f8_nan_(neg: bool, mant: u32, fnz: bool) -> u8 {
    var s: u8  = if (neg) => (0x80) else => 0
    var e: u64 = ((1 as u64) << ((7 - mant) as u64)) - 1
    if fnz {
        return s | (((e << (mant as u64)) | (((1 as u64) << (mant as u64)) - 1)) as u8)
    }

    return s | (((e << (mant as u64)) | ((1 as u64) << ((mant - 1) as u64))) as u8)
}

/// The encoding nearest the f64 `v`: what every float converts through
/// when it is exact in f64 (f32, f16, bf16 and f64 itself).
priv fn f8_from_f64_(v: f64, mant: u32, bias: i32, fnz: bool) -> u8 {
    var w   = v.to_bits()
    var neg = (w >> 63) != 0
    var exp = ((w >> 52) & 0x7FF) as i32
    var man = w & 0xFFFFFFFFFFFFF
    if exp == 0x7FF {
        // NaN in, NaN out. An infinity is E5M2's infinity; E4M3FN has
        // none, and saturating to 448 would turn an overflow signal into a
        // finite number, so it is NaN.
        if man != 0 || fnz {
            return f8_nan_(neg, mant, fnz)
        }

        return f8_encode_(neg, 4096, (1 as u64) << 63, false, mant, bias, fnz)
    }

    if exp == 0 {
        // Zero, or an f64 subnormal: far below half the smallest f8.
        return if (neg) => (0x80) else => 0
    }

    var sig = (man | ((1 as u64) << 52)) << 11
    return f8_encode_(neg, exp - 1023, sig, false, mant, bias, fnz)
}

/// The encoding as an f32, exactly: every value of both formats is one.
priv fn f8_to_f32_(b: u8, mant: u32, bias: i32, fnz: bool) -> f32 {
    var neg              = (b & 0x80) != 0
    var top: u32         = (1 as u32) << mant
    var field            = ((b & 0x7F) as u32) >> mant
    var m                = (b as u32) & (top - 1)
    var emax_field: u32  = ((1 as u32) << (7 - mant)) - 1
    var sw: u32          = if (neg) => ((1 as u32) << 31) else => 0
    if field == emax_field {
        if fnz && m == top - 1 {
            return __builtin_bitcast<f32, u32>(sw | 0x7FC00000)
        }

        if !fnz {
            if m == 0 {
                return __builtin_bitcast<f32, u32>(sw | 0x7F800000)
            }

            return __builtin_bitcast<f32, u32>(sw | 0x7FC00000)
        }
    }

    if field == 0 {
        if m == 0 {
            return __builtin_bitcast<f32, u32>(sw)
        }

        // Subnormal: m * 2^(1 - bias - mant), exact in f32.
        var mag = (m as f32) * __builtin_bitcast<f32, u32>(((128 - bias - (mant as i32)) as u32) << 23)
        return if (neg) => (-mag) else => mag
    }

    var e32 = ((field as i32) - bias + 127) as u32
    return __builtin_bitcast<f32, u32>(sw | (e32 << 23) | (m << (23 - mant)))
}

// === F8E4M3 ===================================================================

/// \class F8E4M3
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
pub class F8E4M3 {
    /// The raw 8-bit encoding: sign, 4 exponent bits, 3 mantissa bits.
    pub var bits: u8 = 0

    /// +0.0.
    pub fn F8E4M3(self) {
        self.bits = 0
    }

    /// The value whose encoding is `b`: what a literal is emitted as (the
    /// compiler rounds the digits once, Native/KShims.hh).
    pub inline static fn from_bits(b: u8) -> F8E4M3 {
        var r = F8E4M3()
        r.bits = b
        return r
    }

    // --- from other types: what `x as f8e4m3` lowers to ---------------------

    /// From f64, rounded once.
    pub fn F8E4M3(self, v: f64) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From f32, rounded once (f32 is exact in f64).
    pub fn F8E4M3(self, v: f32) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From E5M2, rounded once (E5M2 is exact in f64).
    pub fn F8E4M3(self, v: F8E5M2) { self.bits = f8_from_f64_(v.to_f32(), 3, 7, true) }
    /// From i8.
    pub fn F8E4M3(self, v: i8) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From i16.
    pub fn F8E4M3(self, v: i16) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From i32.
    pub fn F8E4M3(self, v: i32) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From i64: through f64, which is exact wherever the result is finite.
    pub fn F8E4M3(self, v: i64) { self.bits = f8_from_f64_(v as f64, 3, 7, true) }
    /// From i128.
    pub fn F8E4M3(self, v: i128) { self.bits = f8_from_f64_(v as f64, 3, 7, true) }
    /// From u8.
    pub fn F8E4M3(self, v: u8) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From u16.
    pub fn F8E4M3(self, v: u16) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From u32.
    pub fn F8E4M3(self, v: u32) { self.bits = f8_from_f64_(v, 3, 7, true) }
    /// From u64.
    pub fn F8E4M3(self, v: u64) { self.bits = f8_from_f64_(v as f64, 3, 7, true) }
    /// From u128.
    pub fn F8E4M3(self, v: u128) { self.bits = f8_from_f64_(v as f64, 3, 7, true) }

    // clang defines __FLT16_MAX__ exactly where _Float16 exists (fmt_buf.k).
    eval if defined!(__FLT16_MAX__) {
        /// From f16, rounded once (f16 is exact in f64).
        pub fn F8E4M3(self, v: f16) { self.bits = f8_from_f64_(v, 3, 7, true) }

        /// To f16, exactly.
        pub fn op as (const self) -> f16 { return self.to_f32() as f16 }
    }

    // The arches clang gives __bf16, but wasm (f256_t.k says why).
    eval if defined!(__x86_64__) || defined!(__i386__) || defined!(__aarch64__) || defined!(__arm__)
         || defined!(__riscv) || defined!(__loongarch__) {
        /// From bf16, rounded once (bf16 is exact in f64).
        pub fn F8E4M3(self, v: bf16) { self.bits = f8_from_f64_(v, 3, 7, true) }

        /// To bf16, exactly.
        pub fn op as (const self) -> bf16 { return self.to_f32() as bf16 }
    }

    // __SIZEOF_FLOAT128__ marks __float128; wasm32 has it without the macro.
    eval if defined!(__SIZEOF_FLOAT128__) || defined!(__wasm__) {
        /// From f128, rounded once.
        pub fn F8E4M3(self, v: f128) { self.bits = F8E4M3::from_f128_(v) }

        /// To f128, exactly.
        pub fn op as (const self) -> f128 { return self.to_f32() as f128 }

        /// The encoding nearest the f128 `v`: its 113-bit significand cut to
        /// the 64 bits f8_encode_ takes, the rest a sticky bit.
        priv static fn from_f128_(v: f128) -> u8 {
            var w   = __builtin_bitcast<u128, f128>(v)
            var neg = (w >> 127) != 0
            var exp = ((w >> 112) & 0x7FFF) as i32
            var man = w & (((1 as u128) << 112) - 1)
            if exp == 0x7FFF {
                return f8_nan_(neg, 3, true)
            }

            if exp == 0 {
                return if (neg) => (0x80) else => 0
            }

            var full = man | ((1 as u128) << 112)
            var sig  = (full >> 49) as u64
            var st   = (full & (((1 as u128) << 49) - 1)) != 0
            return f8_encode_(neg, exp - 16383, sig, st, 3, 7, true)
        }
    }

    // --- to other types: what `x as T` lowers to ----------------------------

    /// The value as an f32, exactly.
    pub fn to_f32(const self) -> f32 { return f8_to_f32_(self.bits, 3, 7, true) }

    /// To f32, exactly.
    pub fn op as (const self) -> f32 { return self.to_f32() }
    /// To f64, exactly.
    pub fn op as (const self) -> f64 { return self.to_f32() }
    /// To i8: toward zero, saturating, NaN 0 (as every float).
    pub fn op as (const self) -> i8 { return self.to_f32() as i8 }
    /// To i16.
    pub fn op as (const self) -> i16 { return self.to_f32() as i16 }
    /// To i32.
    pub fn op as (const self) -> i32 { return self.to_f32() as i32 }
    /// To i64.
    pub fn op as (const self) -> i64 { return self.to_f32() as i64 }
    /// To i128.
    pub fn op as (const self) -> i128 { return self.to_f32() as i128 }
    /// To u8.
    pub fn op as (const self) -> u8 { return self.to_f32() as u8 }
    /// To u16.
    pub fn op as (const self) -> u16 { return self.to_f32() as u16 }
    /// To u32.
    pub fn op as (const self) -> u32 { return self.to_f32() as u32 }
    /// To u64.
    pub fn op as (const self) -> u64 { return self.to_f32() as u64 }
    /// To u128.
    pub fn op as (const self) -> u128 { return self.to_f32() as u128 }

    // --- arithmetic: in f32, the result rounded once -------------------------

    /// self + o.
    pub fn op + (const self, const o: F8E4M3) -> F8E4M3 { return F8E4M3(self.to_f32() + o.to_f32()) }
    /// self - o.
    pub fn op - (const self, const o: F8E4M3) -> F8E4M3 { return F8E4M3(self.to_f32() - o.to_f32()) }
    /// self * o.
    pub fn op * (const self, const o: F8E4M3) -> F8E4M3 { return F8E4M3(self.to_f32() * o.to_f32()) }
    /// self / o.
    pub fn op / (const self, const o: F8E4M3) -> F8E4M3 { return F8E4M3(self.to_f32() / o.to_f32()) }
    /// -self: the sign bit flipped, NaN included.
    pub fn op - (const self) -> F8E4M3 { return F8E4M3::from_bits(self.bits ^ 0x80) }

    // --- comparison: IEEE's, through f32 (NaN unordered, -0 == +0) ----------

    /// self == o.
    pub fn op == (const self, const o: F8E4M3) -> bool { return self.to_f32() == o.to_f32() }
    /// self != o.
    pub fn op != (const self, const o: F8E4M3) -> bool { return self.to_f32() != o.to_f32() }
    /// self < o.
    pub fn op < (const self, const o: F8E4M3) -> bool { return self.to_f32() < o.to_f32() }
    /// self <= o.
    pub fn op <= (const self, const o: F8E4M3) -> bool { return self.to_f32() <= o.to_f32() }
    /// self > o.
    pub fn op > (const self, const o: F8E4M3) -> bool { return self.to_f32() > o.to_f32() }
    /// self >= o.
    pub fn op >= (const self, const o: F8E4M3) -> bool { return self.to_f32() >= o.to_f32() }

    // --- text ------------------------------------------------------------------

    /// Appends self to `b` as an f-string hole: what `{x}` on an `f8e4m3`
    /// lowers to (FStringLowering calls `x.fmt_put_(&buf, spec)`, as for
    /// f256). The digits are rt's (kairo_rt_fmt_f8e4m3): the shortest that
    /// read back as the same encoding, or `spec`'s precision.
    pub fn fmt_put_(const self, b: *FmtBuf, spec: u64) {
        var prec = FmtBuf::prec_(spec)
        var digits: usize = (if prec >= 0 => prec as usize else => 0) + 48
        var slot = b->number_slot_(spec, digits)
        var n: i32 = 0
        unsafe {
            n = kairo_rt_fmt_f8e4m3(unsafe &b->data[slot], digits, self.bits & 0x7F, prec as i32, FmtBuf::conv_(spec))
        }

        b->number_at_(slot, n as usize, (self.bits & 0x80) != 0, spec)
    }

    // --- the agreement check ---------------------------------------------------

    /// Every encoding converts to f32 and back to itself (NaN to the one NaN,
    /// keeping its sign), and the named encodings are OCP's.
    pub static fn verify_() -> bool {
        for var i: u32 = 0; i < 256; ++i {
            var a    = F8E4M3::from_bits(i as u8)
            var back = F8E4M3(a.to_f32())
            if back.bits != a.bits {
                return false
            }
        }

        return F8E4M3(0.0).bits == 0x00 && F8E4M3(1.0).bits == 0x38 && F8E4M3(2.0).bits == 0x40
            && F8E4M3(448.0).bits == 0x7E && F8E4M3(1000.0).bits == 0x7E && F8E4M3(-1.0).bits == 0xB8
            && F8E4M3(464.0).bits == 0x7E && F8E4M3(0.001953125).bits == 0x01
            && F8E4M3(0.0009765625).bits == 0x00 && F8E4M3(0.00146484375).bits == 0x01
    }
}

// === F8E5M2 ===================================================================

/// \class F8E5M2
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
///        Range, not precision. The exponent field is f16's. This is the
///        gradients format.
pub class F8E5M2 {
    /// The raw 8-bit encoding: sign, 5 exponent bits, 2 mantissa bits.
    pub var bits: u8 = 0

    /// +0.0.
    pub fn F8E5M2(self) {
        self.bits = 0
    }

    /// The value whose encoding is `b`.
    pub inline static fn from_bits(b: u8) -> F8E5M2 {
        var r = F8E5M2()
        r.bits = b
        return r
    }

    /// From f64, rounded once.
    pub fn F8E5M2(self, v: f64) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From f32, rounded once.
    pub fn F8E5M2(self, v: f32) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From E4M3, rounded once.
    pub fn F8E5M2(self, v: F8E4M3) { self.bits = f8_from_f64_(v.to_f32(), 2, 15, false) }
    /// From i8.
    pub fn F8E5M2(self, v: i8) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From i16.
    pub fn F8E5M2(self, v: i16) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From i32.
    pub fn F8E5M2(self, v: i32) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From i64.
    pub fn F8E5M2(self, v: i64) { self.bits = f8_from_f64_(v as f64, 2, 15, false) }
    /// From i128.
    pub fn F8E5M2(self, v: i128) { self.bits = f8_from_f64_(v as f64, 2, 15, false) }
    /// From u8.
    pub fn F8E5M2(self, v: u8) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From u16.
    pub fn F8E5M2(self, v: u16) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From u32.
    pub fn F8E5M2(self, v: u32) { self.bits = f8_from_f64_(v, 2, 15, false) }
    /// From u64.
    pub fn F8E5M2(self, v: u64) { self.bits = f8_from_f64_(v as f64, 2, 15, false) }
    /// From u128.
    pub fn F8E5M2(self, v: u128) { self.bits = f8_from_f64_(v as f64, 2, 15, false) }

    eval if defined!(__FLT16_MAX__) {
        /// From f16, rounded once.
        pub fn F8E5M2(self, v: f16) { self.bits = f8_from_f64_(v, 2, 15, false) }

        /// To f16, exactly.
        pub fn op as (const self) -> f16 { return self.to_f32() as f16 }
    }

    eval if defined!(__x86_64__) || defined!(__i386__) || defined!(__aarch64__) || defined!(__arm__)
         || defined!(__riscv) || defined!(__loongarch__) {
        /// From bf16, rounded once.
        pub fn F8E5M2(self, v: bf16) { self.bits = f8_from_f64_(v, 2, 15, false) }

        /// To bf16, exactly.
        pub fn op as (const self) -> bf16 { return self.to_f32() as bf16 }
    }

    eval if defined!(__SIZEOF_FLOAT128__) || defined!(__wasm__) {
        /// From f128, rounded once.
        pub fn F8E5M2(self, v: f128) { self.bits = F8E5M2::from_f128_(v) }

        /// To f128, exactly.
        pub fn op as (const self) -> f128 { return self.to_f32() as f128 }

        /// The encoding nearest the f128 `v` (F8E4M3::from_f128_'s rule).
        priv static fn from_f128_(v: f128) -> u8 {
            var w   = __builtin_bitcast<u128, f128>(v)
            var neg = (w >> 127) != 0
            var exp = ((w >> 112) & 0x7FFF) as i32
            var man = w & (((1 as u128) << 112) - 1)
            if exp == 0x7FFF {
                if man != 0 {
                    return f8_nan_(neg, 2, false)
                }

                return f8_encode_(neg, 4096, (1 as u64) << 63, false, 2, 15, false)
            }

            if exp == 0 {
                return if (neg) => (0x80) else => 0
            }

            var full = man | ((1 as u128) << 112)
            var sig  = (full >> 49) as u64
            var st   = (full & (((1 as u128) << 49) - 1)) != 0
            return f8_encode_(neg, exp - 16383, sig, st, 2, 15, false)
        }
    }

    /// The value as an f32, exactly.
    pub fn to_f32(const self) -> f32 { return f8_to_f32_(self.bits, 2, 15, false) }

    /// To f32, exactly.
    pub fn op as (const self) -> f32 { return self.to_f32() }
    /// To f64, exactly.
    pub fn op as (const self) -> f64 { return self.to_f32() }
    /// To i8: toward zero, saturating, NaN 0.
    pub fn op as (const self) -> i8 { return self.to_f32() as i8 }
    /// To i16.
    pub fn op as (const self) -> i16 { return self.to_f32() as i16 }
    /// To i32.
    pub fn op as (const self) -> i32 { return self.to_f32() as i32 }
    /// To i64.
    pub fn op as (const self) -> i64 { return self.to_f32() as i64 }
    /// To i128.
    pub fn op as (const self) -> i128 { return self.to_f32() as i128 }
    /// To u8.
    pub fn op as (const self) -> u8 { return self.to_f32() as u8 }
    /// To u16.
    pub fn op as (const self) -> u16 { return self.to_f32() as u16 }
    /// To u32.
    pub fn op as (const self) -> u32 { return self.to_f32() as u32 }
    /// To u64.
    pub fn op as (const self) -> u64 { return self.to_f32() as u64 }
    /// To u128.
    pub fn op as (const self) -> u128 { return self.to_f32() as u128 }

    /// self + o.
    pub fn op + (const self, const o: F8E5M2) -> F8E5M2 { return F8E5M2(self.to_f32() + o.to_f32()) }
    /// self - o.
    pub fn op - (const self, const o: F8E5M2) -> F8E5M2 { return F8E5M2(self.to_f32() - o.to_f32()) }
    /// self * o.
    pub fn op * (const self, const o: F8E5M2) -> F8E5M2 { return F8E5M2(self.to_f32() * o.to_f32()) }
    /// self / o.
    pub fn op / (const self, const o: F8E5M2) -> F8E5M2 { return F8E5M2(self.to_f32() / o.to_f32()) }
    /// -self: the sign bit flipped, NaN included.
    pub fn op - (const self) -> F8E5M2 { return F8E5M2::from_bits(self.bits ^ 0x80) }

    /// self == o.
    pub fn op == (const self, const o: F8E5M2) -> bool { return self.to_f32() == o.to_f32() }
    /// self != o.
    pub fn op != (const self, const o: F8E5M2) -> bool { return self.to_f32() != o.to_f32() }
    /// self < o.
    pub fn op < (const self, const o: F8E5M2) -> bool { return self.to_f32() < o.to_f32() }
    /// self <= o.
    pub fn op <= (const self, const o: F8E5M2) -> bool { return self.to_f32() <= o.to_f32() }
    /// self > o.
    pub fn op > (const self, const o: F8E5M2) -> bool { return self.to_f32() > o.to_f32() }
    /// self >= o.
    pub fn op >= (const self, const o: F8E5M2) -> bool { return self.to_f32() >= o.to_f32() }

    /// `{x}` on an `f8e5m2` (F8E4M3::fmt_put_'s rule, kairo_rt_fmt_f8e5m2).
    pub fn fmt_put_(const self, b: *FmtBuf, spec: u64) {
        var prec = FmtBuf::prec_(spec)
        var digits: usize = (if prec >= 0 => prec as usize else => 0) + 48
        var slot = b->number_slot_(spec, digits)
        var n: i32 = 0
        unsafe {
            n = kairo_rt_fmt_f8e5m2(unsafe &b->data[slot], digits, self.bits & 0x7F, prec as i32, FmtBuf::conv_(spec))
        }

        b->number_at_(slot, n as usize, (self.bits & 0x80) != 0, spec)
    }

    /// Every encoding converts to f32 and back to itself (a NaN to the
    /// quiet NaN of its sign), and the named encodings are OCP's.
    pub static fn verify_() -> bool {
        for var i: u32 = 0; i < 256; ++i {
            var a    = F8E5M2::from_bits(i as u8)
            var back = F8E5M2(a.to_f32())
            var nan  = ((i & 0x7C) == 0x7C) && ((i & 0x03) != 0)
            if nan {
                if (back.bits & 0x7F) != 0x7E || (back.bits & 0x80) != (a.bits & 0x80) {
                    return false
                }
            } else if back.bits != a.bits {
                return false
            }
        }

        return F8E5M2(0.0).bits == 0x00 && F8E5M2(1.0).bits == 0x3C && F8E5M2(2.0).bits == 0x40
            && F8E5M2(57344.0).bits == 0x7B && F8E5M2(1.0e30).bits == 0x7C && F8E5M2(-1.0).bits == 0xBC
            && F8E5M2(61440.0).bits == 0x7C && F8E5M2(0.0000152587890625).bits == 0x01
    }
}
