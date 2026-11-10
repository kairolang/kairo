/// --- The Kairo Project ------------------------ AST/PrimitiveLimits.k --- ///
///
///   \brief The associated constants of the primitives -- `i32::MAX`,
///          `f64::EPSILON`, `f32::INFINITY`, `u8::BITS` -- computed from the
///          builtin table, never from a host `<limits.h>` / `<float.h>`.
///
///   \detail
///     Every value is derived from facts CanonicalNodes.k already holds: an
///     integer's width and signedness, a float's FloatLayout (exponent and
///     stored mantissa bits, bias, whether the all-ones exponent is infinity
///     or NaN, x87's explicit integer bit). Nothing is tabulated per type, so
///     a format added there gets its limits here with no new row, and a
///     typo in one row cannot make one type's EPSILON wrong.
///
///     The integer-valued answers (every integer limit, and the descriptive
///     float ones: MANTISSA_DIGITS, the exponents, ...) are values
///         PrimitiveLimitDesugar
///     mints as literals, so they fold wherever a literal folds. The
///     float-valued answers are C++ text: an exact hex-float literal for a
///     finite value (each one is a power of two or a run of mantissa ones,
///     so hex is exact and needs no rounding), and clang's `__builtin_inf*`
///     / `__builtin_nan*` for the two values no literal spells.
///
///     The decimal ones (DIGITS, MAX_DIGITS, MIN_10_EXP, MAX_10_EXP) take
///     log10(2) in fixed point, 30102999566 / 10^11, which is below the true
///     value by under 4e-12: off by one only for an exponent past 10^11, and
///     every format here is below 2^15.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::LangItems::LowerTargets
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_info,
}

/// \enum PrimLimit
/// \brief One associated constant. `None` is "not a limit name".
pub enum PrimLimit derives u8 {
    None = 0,
    Min,          ///< integers: the smallest value; floats: the most negative finite (-MAX)
    Max,          ///< the largest (finite) value
    Bits,         ///< integers: value width; floats: storage width
    MinPositive,  ///< smallest positive normal
    MinSubnormal, ///< smallest positive subnormal
    Epsilon,      ///< 1.0's next value up, minus 1.0
    Infinity,
    NegInfinity,
    Nan,            ///< a quiet NaN
    MantissaDigits, ///< significand bits, implicit bit included
    Digits,         ///< decimal digits that survive text -> float -> text
    MaxDigits,      ///< decimal digits that float -> text -> float needs
    MinExp,         ///< one more than the smallest normal binary exponent
    MaxExp,         ///< one more than the largest binary exponent
    Min10Exp,       ///< smallest n with 10^n normal
    Max10Exp,       ///< largest n with 10^n finite
    Radix,          ///< always 2
}

/// \struct PrimLimitInt
/// \brief An integer limit as sign and 128-bit magnitude: the shape a
///        literal (plus a leading `-`) carries, so `i64::MIN` needs no
///        value that overflows on the way.
pub struct PrimLimitInt {
    pub var neg: bool
    pub var lo:  u64
    pub var hi:  u64
}

pub class PrimitiveLimits {
    /// log10(2), in fixed point over LOG_DEN.
    static fn _log_num() -> i64 {
        return 30102999566
    }

    static fn _log_den() -> i64 {
        return 100000000000
    }

    pub static fn of_name(const name: string) -> PrimLimit {
        if name == "MIN" {
            return PrimLimit::Min
        }

        if name == "MAX" {
            return PrimLimit::Max
        }

        if name == "BITS" {
            return PrimLimit::Bits
        }

        if name == "MIN_POSITIVE" {
            return PrimLimit::MinPositive
        }

        if name == "MIN_SUBNORMAL" {
            return PrimLimit::MinSubnormal
        }

        if name == "EPSILON" {
            return PrimLimit::Epsilon
        }

        if name == "INFINITY" {
            return PrimLimit::Infinity
        }

        if name == "NEG_INFINITY" {
            return PrimLimit::NegInfinity
        }

        if name == "NAN" {
            return PrimLimit::Nan
        }

        if name == "MANTISSA_DIGITS" {
            return PrimLimit::MantissaDigits
        }

        if name == "DIGITS" {
            return PrimLimit::Digits
        }

        if name == "MAX_DIGITS" {
            return PrimLimit::MaxDigits
        }

        if name == "MIN_EXP" {
            return PrimLimit::MinExp
        }

        if name == "MAX_EXP" {
            return PrimLimit::MaxExp
        }

        if name == "MIN_10_EXP" {
            return PrimLimit::Min10Exp
        }

        if name == "MAX_10_EXP" {
            return PrimLimit::Max10Exp
        }

        if name == "RADIX" {
            return PrimLimit::Radix
        }

        return PrimLimit::None
    }

    /// The source spelling of \p k, for diagnostics.
    pub static fn name_of(k: PrimLimit) -> string {
        match k {
            case PrimLimit::Min {
                return "MIN"
            } case PrimLimit::Max {
                return "MAX"
            } case PrimLimit::Bits {
                return "BITS"
            } case PrimLimit::MinPositive {
                return "MIN_POSITIVE"
            } case PrimLimit::MinSubnormal {
                return "MIN_SUBNORMAL"
            } case PrimLimit::Epsilon {
                return "EPSILON"
            } case PrimLimit::Infinity {
                return "INFINITY"
            } case PrimLimit::NegInfinity {
                return "NEG_INFINITY"
            } case PrimLimit::Nan {
                return "NAN"
            } case PrimLimit::MantissaDigits {
                return "MANTISSA_DIGITS"
            } case PrimLimit::Digits {
                return "DIGITS"
            } case PrimLimit::MaxDigits {
                return "MAX_DIGITS"
            } case PrimLimit::MinExp {
                return "MIN_EXP"
            } case PrimLimit::MaxExp {
                return "MAX_EXP"
            } case PrimLimit::Min10Exp {
                return "MIN_10_EXP"
            } case PrimLimit::Max10Exp {
                return "MAX_10_EXP"
            } case PrimLimit::Radix {
                return "RADIX"
            } default {
                return ""
            }
        }
    }

    /// A float whose layout columns are filled: every float but f256 / f512,
    /// whose fraction and bias do not fit them (CanonicalNodes.k).
    static fn is_layout_float(b: BuiltinKind) -> bool {
        var *info = builtin_info(b)
        return info->is_float() && info->fp.exp != 0
    }

    pub static fn is_float_limit(k: PrimLimit) -> bool {
        return k != PrimLimit::None
            && k != PrimLimit::Min
            && k != PrimLimit::Max
            && k != PrimLimit::Bits
    }

    /// Whether \p b has \p k. A limit a format does not have is not
    /// defined, never a substitute value (no infinity for f8e4m3).
    pub static fn exists(b: BuiltinKind, k: PrimLimit) -> bool {
        if k == PrimLimit::None {
            return false
        }

        var *info = builtin_info(b)
        if info->is_integer() || b == BuiltinKind::Char {
            return k == PrimLimit::Min || k == PrimLimit::Max || k == PrimLimit::Bits
        }

        if b == BuiltinKind::Byte {
            return k == PrimLimit::Bits
        }

        if !PrimitiveLimits::is_layout_float(b) {
            return false
        }

        if k == PrimLimit::Infinity || k == PrimLimit::NegInfinity {
            return info->fp.has_inf
        }

        return true
    }

    /// The type of \p b's \p k: \p b itself for a value, `u32` for a count,
    /// `i32` for an exponent.
    pub static fn result_kind(b: BuiltinKind, k: PrimLimit) -> BuiltinKind {
        match k {
            case PrimLimit::Bits {
                return BuiltinKind::U32
            } case PrimLimit::MantissaDigits {
                return BuiltinKind::U32
            } case PrimLimit::Digits {
                return BuiltinKind::U32
            } case PrimLimit::MaxDigits {
                return BuiltinKind::U32
            } case PrimLimit::Radix {
                return BuiltinKind::U32
            } case PrimLimit::MinExp {
                return BuiltinKind::I32
            } case PrimLimit::MaxExp {
                return BuiltinKind::I32
            } case PrimLimit::Min10Exp {
                return BuiltinKind::I32
            } case PrimLimit::Max10Exp {
                return BuiltinKind::I32
            } default {
                return b
            }
        }
    }

    /// The answer is a value of the float \p b itself (spelled by float_cxx),
    /// not an integer.
    pub static fn is_float_valued(b: BuiltinKind, k: PrimLimit) -> bool {
        return PrimitiveLimits::is_layout_float(b) && PrimitiveLimits::result_kind(b, k) == b
    }

    /// # float layout facts

    /// Significand bits, the implicit one included (x87 stores its own).
    static fn precision(b: BuiltinKind) -> i64 {
        var *fp = &builtin_info(b)->fp
        var m   = (fp->mant as i64)
        if fp->explicit_int_bit {
            return m
        }

        return m + 1
    }

    /// The smallest normal exponent: 1 - bias.
    static fn emin(b: BuiltinKind) -> i64 {
        return 1 - (builtin_info(b)->fp.bias as i64)
    }

    /// The largest finite exponent. With infinities the all-ones exponent is
    /// theirs; without (E4M3FN) it holds finite values, all but NaN's.
    static fn emax(b: BuiltinKind) -> i64 {
        var *fp      = &builtin_info(b)->fp
        var one: i64 = 1
        var top      = (one << (fp->exp as i64)) - 1
        if fp->has_inf {
            top -= 1
        }

        return top - (fp->bias as i64)
    }

    /// floor(x * log10(2)) and ceil(x * log10(2)), for either sign of x.
    static fn _floor_log(x: i64) -> i64 {
        var p = x * PrimitiveLimits::_log_num()
        var d = PrimitiveLimits::_log_den()
        var q = p / d
        if p % d != 0 && p < 0 {
            q -= 1
        }

        return q
    }

    static fn _ceil_log(x: i64) -> i64 {
        var p = x * PrimitiveLimits::_log_num()
        var d = PrimitiveLimits::_log_den()
        var q = p / d
        if p % d != 0 && p > 0 {
            q += 1
        }

        return q
    }

    static fn _small(v: i64) -> PrimLimitInt {
        var r = PrimLimitInt{}
        r.neg = v < 0
        r.lo  = if (v < 0) => ((-v) as u64) else => (v as u64)
        r.hi  = 0
        return r
    }

    /// An integer-valued limit: any limit of an integer or `char`, BITS of
    /// anything, and the descriptive counts and exponents of a float.
    /// \p width is \p b's value width (the target's for usize / isize);
    /// \p storage_bits a float's storage width, for its BITS. Integers wider
    /// than 128 bits are the caller's to refuse.
    pub static fn int_value(b:            BuiltinKind,
                            k:            PrimLimit,
                            width:        usize,
                            storage_bits: usize) -> PrimLimitInt {
        var *info = builtin_info(b)
        var r     = PrimLimitInt{}
        r.neg = false
        r.lo  = 0
        r.hi  = 0
        var ones     = ~(0 as u64)
        var one: u64 = 1

        if k == PrimLimit::Bits {
            if PrimitiveLimits::is_layout_float(b) {
                r.lo = (storage_bits as u64)
            } else {
                r.lo = (width as u64)
            }

            return r
        }

        if b == BuiltinKind::Char {
            if k == PrimLimit::Max {
                r.lo = 0x10FFFF
            }

            return r
        }

        if info->is_integer() {
            var signed_ = info->is_signed()
            if k == PrimLimit::Min {
                if !signed_ {
                    return r
                }

                r.neg = true
                if width >= 128 {
                    r.hi = one << 63
                } else {
                    r.lo = one << ((width - 1) as u64)
                }

                return r
            }

            // Max
            if width >= 128 {
                r.lo = ones
                r.hi = if (signed_) => (ones >> 1) else => ones
                return r
            }

            var w = if (signed_) => (width - 1) else => width
            r.lo = if (w >= 64) => (ones) else => (one << (w as u64)) - 1
            return r
        }

        var p = PrimitiveLimits::precision(b)
        match k {
            case PrimLimit::MantissaDigits {
                return PrimitiveLimits::_small(p)
            } case PrimLimit::Digits {
                return PrimitiveLimits::_small(PrimitiveLimits::_floor_log(p - 1))
            } case PrimLimit::MaxDigits {
                return PrimitiveLimits::_small(1 + PrimitiveLimits::_ceil_log(p))
            } case PrimLimit::MinExp {
                return PrimitiveLimits::_small(PrimitiveLimits::emin(b) + 1)
            } case PrimLimit::MaxExp {
                return PrimitiveLimits::_small(PrimitiveLimits::emax(b) + 1)
            } case PrimLimit::Min10Exp {
                return PrimitiveLimits::_small(PrimitiveLimits::_ceil_log(PrimitiveLimits::emin(b)))
            }

            // MAX is just under 2^(emax+1), whose log10 is never an integer.
            case PrimLimit::Max10Exp {
                return PrimitiveLimits::_small(
                    PrimitiveLimits::_floor_log(PrimitiveLimits::emax(b) + 1),
                )
            } case PrimLimit::Radix {
                return PrimitiveLimits::_small(2)
            } default {
                return r
            }
        }
    }

    /// # float values as C++

    static fn _hex_digit(v: u32) -> string {
        var digits = "0123456789abcdef"
        var s      = ""
        s.push_back(digits[v as usize])
        return s
    }

    /// The fraction digits of MAX's significand: every stored fraction bit
    /// set, left-aligned in hex digits -- but the last one clear on a format
    /// without infinities, where the all-ones significand at the top
    /// exponent is NaN (E4M3FN: 1.110b, 448).
    static fn _max_fraction(b: BuiltinKind) -> string {
        var f  = PrimitiveLimits::precision(b) - 1
        var nd = (f + 3) / 4
        var s  = ""
        for var i: i64 = 0; i < nd - 1; ++i {
            s += "f"
        }

        var r         = ((f - 4 * (nd - 1)) as u32) // bits in the last digit, 1..4
        var last: u32 = 15 << 4 - r & 15
        if !builtin_info(b)->fp.has_inf {
            last -= 1 << 4 - r
        }

        s += PrimitiveLimits::_hex_digit(last)
        return s
    }

    /// The literal suffix that makes C++ read a literal at \p b; "" for
    /// double, and for the library formats (f8*), which take a double.
    static fn _suffix(b: BuiltinKind) -> string {
        match b {
            case BuiltinKind::F16 {
                return "f16"
            } case BuiltinKind::F32 {
                return "f"
            } case BuiltinKind::BF16 {
                return "f"
            } case BuiltinKind::F80 {
                return "L"
            } case BuiltinKind::F128 {
                return "Q"
            } default {
                return ""
            }
        }
    }

    /// The type tag of clang's `__builtin_inf*` / `__builtin_nan*` for \p b:
    /// bf16 has none and takes float's (then converts); the library formats
    /// (f8*) take double's.
    static fn _builtin_tag(b: BuiltinKind) -> string {
        match b {
            case BuiltinKind::F16 {
                return "f16"
            } case BuiltinKind::F32 {
                return "f"
            } case BuiltinKind::BF16 {
                return "f"
            } case BuiltinKind::F80 {
                return "l"
            } case BuiltinKind::F128 {
                return "f128"
            } default {
                return ""
            }
        }
    }

    /// The C++ expression for a float-valued limit (is_float_valued). Every
    /// finite one is an exact hex-float literal at \p b's own precision;
    /// bf16, which has no literal suffix, rounds nothing through float.
    pub static fn float_cxx(b: BuiltinKind, k: PrimLimit) -> string {
        var sfx = PrimitiveLimits::_suffix(b)
        var v   = ""
        match k {
            case PrimLimit::Max {
                v = "0x1." + PrimitiveLimits::_max_fraction(
                    b,
                ) + f"p+{PrimitiveLimits::emax(b)}" + sfx
            } case PrimLimit::Min {
                v = "-0x1." + PrimitiveLimits::_max_fraction(
                    b,
                ) + f"p+{PrimitiveLimits::emax(b)}" + sfx
            } case PrimLimit::MinPositive {
                v = f"0x1p{PrimitiveLimits::emin(b)}" + sfx
            } case PrimLimit::MinSubnormal {
                v = f"0x1p{PrimitiveLimits::emin(b) - (PrimitiveLimits::precision(b) - 1)}" + sfx
            } case PrimLimit::Epsilon {
                v = f"0x1p-{PrimitiveLimits::precision(b) - 1}" + sfx
            } case PrimLimit::Infinity {
                v = LowerTargets::float_inf(PrimitiveLimits::_builtin_tag(b)) + "()"
            } case PrimLimit::NegInfinity {
                v = "-" + LowerTargets::float_inf(PrimitiveLimits::_builtin_tag(b)) + "()"
            } case PrimLimit::Nan {
                v = LowerTargets::float_nan(PrimitiveLimits::_builtin_tag(b)) + "(\"\")"
            } default {
                return ""
            }
        }

        if b == BuiltinKind::BF16 {
            return "static_cast<" + builtin_info(b)->cxx + ">(" + v + ")"
        }

        return "(" + v + ")"
    }
}
