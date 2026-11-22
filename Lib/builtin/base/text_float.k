/// builtin/base/text_float.k
///
/// f64 / f32 <-> decimal text on raw byte buffers.
///
/// Value to text gives the shortest decimal that reads back as the same
/// value (Schubfach: R. Giulietti, "The Schubfach way to render doubles").
/// Text to value is correctly rounded, to nearest with ties to even:
/// Clinger's exact fast path where it applies, Eisel-Lemire on the first
/// 19 significant digits (D. Lemire, "Number Parsing at a Gigabyte per
/// Second"), and exact big-integer arithmetic on up to 768 digits for the
/// inputs it cannot settle.
///
/// Value to text is integer arithmetic on the bit pattern. Text to value is
/// too, except for one f64 (f32) multiply or divide of exact operands where
/// the float unit rounds each operation once (x86-64, AArch64): that result
/// assumes the default rounding mode, to nearest. Nothing here allocates,
/// calls libc or depends on byte order.

import base::intrinsics::*
import base::text_float_tables::*
import base::text_int::*
import string::*

/// The longest text of each type: sign, 17 (9) digits, the point and the
/// exponent `e-324` (`e-45`).
prot eval F64_TEXT_MAX: usize = 24
prot eval F32_TEXT_MAX: usize = 15

/// A finite nonzero magnitude as `sig * 10^exp`, `sig` without a trailing
/// zero digit.
prot struct FloatDecimal {
    pub var sig: u64
    pub var exp: i32
}

/// The two words of a 64 x 64 -> 128 product.
struct Wide {
    var hi: u64
    var lo: u64
}

/// The full product of `a` and `b`. Targets without a 64-bit multiplier
/// build it from four 32 x 32 products.
inline fn mul64(a: u64, b: u64) -> Wide {
    eval if NUMTEXT_WIDE {
        var r = (a as u128) * (b as u128)
        return Wide { hi: (r >> 64) as u64, lo: r as u64 }
    } else {
        var a0  = a & 0xFFFFFFFF
        var a1  = a >> 32
        var b0  = b & 0xFFFFFFFF
        var b1  = b >> 32
        var p00 = a0 * b0
        var p01 = a0 * b1
        var p10 = a1 * b0
        var p11 = a1 * b1
        var mid = (p00 >> 32) + (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF)
        return Wide {
            hi: p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32),
            lo: (mid << 32) | (p00 & 0xFFFFFFFF),
        }
    }
}

// --- value to text: digits -----------------------------------------------------

/// Drops the trailing zero digits of `sig` into the exponent.
fn strip_zeros(sig: u64, exp: i32) -> FloatDecimal {
    var s = sig
    var e = exp
    loop {
        var q = s / 10
        if q * 10 != s {
            break
        }

        s = q
        e += 1
    }

    return FloatDecimal { sig: s, exp: e }
}

/// floor(g * cp / 2^128) with the lowest bit set when the discarded part
/// is more than one unit of the middle word: Schubfach's round-to-odd
/// estimate of `cp * 10^-k`.
inline fn round_to_odd64(g_hi: u64, g_lo: u64, cp: u64) -> u64 {
    var x    = mul64(cp, g_lo)
    var y    = mul64(cp, g_hi)
    var y_lo = y.lo + x.hi
    var y_hi = y.hi + (if y_lo < x.hi => 1u64 else => 0u64)
    return y_hi | (if y_lo > 1 => 1u64 else => 0u64)
}

/// The 32-bit counterpart: floor(g * cp / 2^64), odd when bits 32..63 of
/// the product exceed one.
inline fn round_to_odd32(g: u64, cp: u32) -> u32 {
    var p  = mul64(g, cp)
    var y1 = p.hi as u32
    var y0 = (p.lo >> 32) as u32
    return y1 | (if y0 > 1 => 1u32 else => 0u32)
}

/// The shortest decimal that rounds to the f64 with bit pattern `bits`.
///
/// **Precondition:** `bits` has the sign bit clear and is neither zero, an infinity nor
/// a NaN.
prot fn f64_to_decimal(bits: u64) -> FloatDecimal {
    var frac     = bits & 0x000FFFFFFFFFFFFF
    var bexp     = ((bits >> 52) & 0x7FF) as i32
    var c        = frac
    var q:   i32 = -1074
    if bexp != 0 {
        c = frac | 0x0010000000000000
        q = bexp - 1075
        // An integer below 2^53 is its own shortest decimal.
        if q <= 0 && q > -53 {
            var sh = (0 - q) as u32
            if (c & ((1u64 << sh) - 1)) == 0 {
                return strip_zeros(c >> sh, 0)
            }
        }
    }

    // The rounding interval of c * 2^q, in quarter units: (cbl, cbr), closed
    // when c is even. The lower gap is half as wide at a power of two.
    var odd:   u64 = c & 1
    var closer     = frac == 0 && bexp > 1
    var cbl        = 4 * c - 2 + (if closer => 1u64 else => 0u64)
    var cb         = 4 * c
    var cbr        = 4 * c + 2

    // k = floor(log10(2^q)), or floor(log10(3/4 * 2^q)) at a power of two;
    // h puts cb * 2^h * 10^-k into the estimate's range.
    var k   = (q * 1262611 - (if closer => 524031 else => 0)) >> 22
    var nk  = 0 - k
    var h   = (q + ((nk * 1741647) >> 19) + 1) as u32
    var idx = ((nk - NUMTEXT_POW10_MIN) * 2) as usize

    // The estimate needs 10^-k rounded up; the table rounds down outside
    // [-27, 55] (float_tables.k).
    var g_hi = NUMTEXT_POW10[idx]
    var g_lo = NUMTEXT_POW10[idx + 1] + (if nk > 55 || nk < -27 => 1u64 else => 0u64)

    var vbl   = round_to_odd64(g_hi, g_lo, cbl << h)
    var vb    = round_to_odd64(g_hi, g_lo, cb << h)
    var vbr   = round_to_odd64(g_hi, g_lo, cbr << h)
    var lower = vbl + odd
    var upper = vbr - odd

    // One digit fewer when exactly one of the two neighbours at that length
    // lies in the interval.
    var s = vb >> 2
    if s >= 10 {
        var sp        = s / 10
        var up_inside = lower <= 40 * sp
        var wp_inside = 40 * sp + 40 <= upper
        if up_inside != wp_inside {
            return strip_zeros(sp + (if wp_inside => 1u64 else => 0u64), k + 1)
        }
    }

    var u_inside = lower <= 4 * s
    var w_inside = 4 * s + 4 <= upper
    if u_inside != w_inside {
        return strip_zeros(s + (if w_inside => 1u64 else => 0u64), k)
    }

    // Both or neither: the closer one, ties to even.
    var mid      = 4 * s + 2
    var round_up = vb > mid || (vb == mid && (s & 1) != 0)
    return strip_zeros(s + (if round_up => 1u64 else => 0u64), k)
}

/// The shortest decimal that rounds to the f32 with bit pattern `bits`.
///
/// **Precondition:** `bits` has the sign bit clear and is neither zero, an infinity nor
/// a NaN.
prot fn f32_to_decimal(bits: u32) -> FloatDecimal {
    var frac     = bits & 0x007FFFFF
    var bexp     = ((bits >> 23) & 0xFF) as i32
    var c        = frac
    var q:   i32 = -149
    if bexp != 0 {
        c = frac | 0x00800000
        q = bexp - 150
        if q <= 0 && q > -24 {
            var sh = (0 - q) as u32
            if (c & ((1u32 << sh) - 1)) == 0 {
                return strip_zeros((c >> sh), 0)
            }
        }
    }

    var odd:   u32 = c & 1
    var closer     = frac == 0 && bexp > 1
    var cbl        = 4 * c - 2 + (if closer => 1u32 else => 0u32)
    var cb         = 4 * c
    var cbr        = 4 * c + 2

    var k   = (q * 1262611 - (if closer => 524031 else => 0)) >> 22
    var nk  = 0 - k
    var h   = (q + ((nk * 1741647) >> 19) + 1) as u32
    var idx = ((nk - NUMTEXT_POW10_MIN) * 2) as usize

    // The high word rounded up: exact only where the low word is zero,
    // which is [0, 27] (float_tables.k).
    var g = NUMTEXT_POW10[idx] + (if nk < 0 || nk > 27 => 1u64 else => 0u64)

    var vbl   = round_to_odd32(g, cbl << h)
    var vb    = round_to_odd32(g, cb << h)
    var vbr   = round_to_odd32(g, cbr << h)
    var lower = vbl + odd
    var upper = vbr - odd

    var s = vb >> 2
    if s >= 10 {
        var sp        = s / 10
        var up_inside = lower <= 40 * sp
        var wp_inside = 40 * sp + 40 <= upper
        if up_inside != wp_inside {
            return strip_zeros(
                (sp + (if wp_inside => 1u32 else => 0u32)),
                k + 1,
            )
        }
    }

    var u_inside = lower <= 4 * s
    var w_inside = 4 * s + 4 <= upper
    if u_inside != w_inside {
        return strip_zeros((s + (if w_inside => 1u32 else => 0u32)), k)
    }

    var mid      = 4 * s + 2
    var round_up = vb > mid || (vb == mid && (s & 1) != 0)
    return strip_zeros((s + (if round_up => 1u32 else => 0u32)), k)
}

// --- value to text: layout -----------------------------------------------------

/// 10^0 .. 10^19.
priv static const NUMTEXT_POW10_U64: [u64; 20] = [
    1,                 10,                 100,                 1000,
    10000,             100000,             1000000,             10000000,
    100000000,         1000000000,         10000000000,         100000000000,
    1000000000000,     10000000000000,     100000000000000,     1000000000000000,
    10000000000000000, 100000000000000000, 1000000000000000000, 10000000000000000000,
]

/// The number of decimal digits of `v`, for `v >= 1`: the bit length times
/// log10(2) (1233 / 4096) is the count or one less, and one compare with a
/// power of ten decides which.
inline fn decimal_digits(v: u64) -> usize {
    var t = ((64 - __builtin_clz(v)) * 1233) >> 12
    return (t as usize) + (if v >= NUMTEXT_POW10_U64[t as usize] => 1usize else => 0usize)
}

/// Moves the `len` bytes at `buf[at + 1 ..)` to `buf[at ..)`, for
/// `1 <= len <= 16`. Every load comes before every store, so the overlap is
/// harmless, and nothing outside `buf[at .. at + len]` is written.
inline fn shift_left_one(buf: unsafe *u8, at: usize, len: usize) {
    unsafe {
        if len >= 8 {
            var a = read_le64(buf + (at + 1))
            var b = read_le64(buf + (at + len - 7))
            write_le64(buf + at, a)
            write_le64(buf + (at + len - 8), b)
        } else if len >= 4 {
            var a = read_le32(buf + (at + 1))
            var b = read_le32(buf + (at + len - 3))
            write_le32(buf + at, a)
            write_le32(buf + (at + len - 4), b)
        } else {
            var a = buf[at + 1]
            var b = buf[at + 1 + (len >> 1)]
            var c = buf[at + len]
            buf[at]              = a
            buf[at + (len >> 1)] = b
            buf[at + len - 1]    = c
        }
    }
}

/// Writes `sig * 10^exp` at `buf[at ..)` and returns the index after it.
///
/// With e the exponent of the first digit: plain decimal notation when
/// -4 <= e < `fixed_below`, otherwise `d[.ddd]e[+-]XX` with at least two
/// exponent digits. A whole number has no point and no fraction.
///
/// The digit count is known first, so the digits are written once, in
/// place; where a point goes among them they are written one byte to the
/// right and the digits before the point move back over it.
///
/// **Precondition:** `fixed_below <= 17`; `buf[at ..)` has room for the text and for 8
/// bytes past `at` in any case.
fn layout_decimal(buf: unsafe *u8, at: usize, sig: u64, exp: i32, fixed_below: i32) -> usize {
    var n = decimal_digits(sig)
    var e = exp + (n as i32) - 1
    var o = at

    if e < -4 || e >= fixed_below {
        put_u64(buf, o + 1 + n, sig)
        buf[o] = buf[o + 1]
        o += 1
        if n > 1 {
            buf[o] = 46
            o += n
        }

        buf[o] = 101
        o += 1
        if e < 0 {
            buf[o] = 45
            e      = 0 - e
        } else {
            buf[o] = 43
        }

        o += 1
        if e >= 100 {
            buf[o] = (48 + e / 100) as u8
            o += 1
            e = e % 100
        }

        buf[o]     = (48 + e / 10) as u8
        buf[o + 1] = (48 + e % 10) as u8
        return o + 2
    }

    if e < 0 {
        // "0." and -e - 1 (at most 3) zeros, then the digits.
        var z = (0 - e - 1) as usize
        unsafe {
            write_le32(buf + (o + 2), 0x30303030u64)
        }

        buf[o]     = 48
        buf[o + 1] = 46
        return put_u64(buf, o + 2 + z + n, sig) + n
    }

    var int_digits = (e + 1) as usize
    if n > int_digits {
        // The point among the digits: at most 16 of them before it.
        put_u64(buf, o + 1 + n, sig)
        shift_left_one(buf, o, int_digits)
        buf[o + int_digits] = 46
        return o + 1 + n
    }

    // A whole number: the digits, then zeros up to the point's place, which
    // is at most 17 digits in. The zeros go first and never past the text
    // or 8 bytes from `at`.
    unsafe {
        write_le64(buf + o, ZEROS8)
        if int_digits > 8 {
            write_le64(buf + (o + int_digits - 8), ZEROS8)
            if int_digits > 16 {
                write_le64(buf + (o + 8), ZEROS8)
            }
        }
    }

    put_u64(buf, o + n, sig)
    return o + int_digits
}

/// Writes "inf" or "nan" at `buf[at ..)` and returns the index after it.
fn layout_special(buf: unsafe *u8, at: usize, nan: bool) -> usize {
    if nan {
        buf[at]     = 110
        buf[at + 1] = 97
        buf[at + 2] = 110
    } else {
        buf[at]     = 105
        buf[at + 1] = 110
        buf[at + 2] = 102
    }

    return at + 3
}

/// Writes the shortest text of `v` that reads back as `v` at `buf[0 ..)`
/// and returns its length.
///
/// Zero is `0` or `-0`, an infinity `inf` or `-inf`, and every NaN `nan`
/// whatever its sign and payload.
///
/// **Precondition:** `buf` is valid for writes of `F64_TEXT_MAX` (24) bytes.
prot fn f64_to_text(v: f64, buf: unsafe *u8) -> usize {
    var bits: u64 = 0
    unsafe {
        __builtin_copy(&bits as unsafe *u8, &v as unsafe *const u8, 8)
    }

    var mag = bits & 0x7FFFFFFFFFFFFFFF
    if mag > 0x7FF0000000000000 {
        return layout_special(buf, 0, true)
    }

    var o: usize = 0
    if mag != bits {
        buf[0] = 45
        o      = 1
    }

    if mag == 0x7FF0000000000000 {
        return layout_special(buf, o, false)
    }

    if mag == 0 {
        buf[o] = 48
        return o + 1
    }

    var d = f64_to_decimal(mag)
    return layout_decimal(buf, o, d.sig, d.exp, 17)
}

/// The f32 counterpart of `f64_to_text`.
///
/// **Precondition:** `buf` is valid for writes of `F32_TEXT_MAX` (15) bytes.
prot fn f32_to_text(v: f32, buf: unsafe *u8) -> usize {
    var bits: u32 = 0
    unsafe {
        __builtin_copy(&bits as unsafe *u8, &v as unsafe *const u8, 4)
    }

    var mag = bits & 0x7FFFFFFF
    if mag > 0x7F800000 {
        return layout_special(buf, 0, true)
    }

    var o: usize = 0
    if mag != bits {
        buf[0] = 45
        o      = 1
    }

    if mag == 0x7F800000 {
        return layout_special(buf, o, false)
    }

    if mag == 0 {
        buf[o] = 48
        return o + 1
    }

    var d = f32_to_decimal(mag)
    return layout_decimal(buf, o, d.sig, d.exp, 9)
}

// --- text to value: Eisel-Lemire -------------------------------------------------

/// What `eisel_lemire` returns when the 128-bit product cannot decide the
/// rounding.
eval FLOAT_UNDECIDED: u64 = 0xFFFFFFFFFFFFFFFF

/// The bit pattern of the float nearest `w * 10^q`, ties to even, for an
/// exact nonzero `w`; an infinity's pattern when it is out of range, and
/// `FLOAT_UNDECIDED` when two words of 10^q are not enough to be sure.
///
/// `F` is the result type, f64 or f32: a generic, so each type gets its own
/// copy with the width tests folded.
fn <F> eisel_lemire(w: u64, q: i64) -> u64 {
    var single         = __builtin_is_same<F, f32>()
    var mant_bits: i32 = if single => 23 else => 52
    var min_exp:   i32 = if single => -127 else => -1023
    var inf_pow:   i32 = if single => 0xFF else => 0x7FF

    // w < 10^19, so below these the value is under half the smallest
    // subnormal, and above them it exceeds the largest finite value.
    if q < (if single => -65 else => -342) {
        return 0
    }

    if q > (if single => 38 else => 308) {
        return (inf_pow as u64) << (mant_bits as u32)
    }

    var qi  = q as i32
    var lz  = __builtin_clz(w)
    var m   = w << lz
    var idx = ((qi - NUMTEXT_POW10_MIN) * 2) as usize

    // The high word of m * 10^q decides unless the bits below the
    // precision are all ones, where the low table word can still carry in.
    var first     = mul64(m, NUMTEXT_POW10[idx])
    var hi        = first.hi
    var lo        = first.lo
    var mask: u64 = 0xFFFFFFFFFFFFFFFF >> ((mant_bits + 3) as u32)
    if (hi & mask) == mask {
        var second = mul64(m, NUMTEXT_POW10[idx + 1])
        lo = lo + second.hi
        if second.hi > lo {
            hi += 1
        }
    }

    // The table value is exact for q in [-27, 55]; outside it a low word of
    // all ones means the truncated tail could still carry.
    if lo == 0xFFFFFFFFFFFFFFFF && (qi < -27 || qi > 55) {
        return FLOAT_UNDECIDED
    }

    var upper = (hi >> 63) as i32
    var shift = (upper + 64 - mant_bits - 3) as u32
    var mant  = hi >> shift
    var pow2  = (((152170 + 65536) * qi) >> 16) + 63 + upper - (lz as i32) - min_exp

    if pow2 <= 0 {
        // Subnormal: the extra shift leaves no halfway case to resolve.
        if 1 - pow2 >= 64 {
            return 0
        }

        mant = mant >> ((1 - pow2) as u32)
        mant = mant + (mant & 1)
        mant = mant >> 1
        var sub_pow: u64 = if mant < (1u64 << (mant_bits as u32)) => 0u64 else => 1u64
        return mant | (sub_pow << (mant_bits as u32))
    }

    // Exactly halfway: the product has no bits below the rounding bit. That
    // happens only when 5^q fits the spare bits, so only for these q.
    var even_lo: i32 = if single => -17 else => -4
    var even_hi: i32 = if single => 10 else => 23
    if lo <= 1 && qi >= even_lo && qi <= even_hi && (mant & 3) == 1 {
        if (mant << shift) == hi {
            mant = mant & 0xFFFFFFFFFFFFFFFE
        }
    }

    mant = mant + (mant & 1)
    mant = mant >> 1
    if mant >= (2u64 << (mant_bits as u32)) {
        mant = 1u64 << (mant_bits as u32)
        pow2 += 1
    }

    mant = mant & ((1u64 << (mant_bits as u32)) - 1)
    if pow2 >= inf_pow {
        return (inf_pow as u64) << (mant_bits as u32)
    }

    return ((pow2 as u64) << (mant_bits as u32)) | mant
}

// --- text to value: exact ---------------------------------------------------------

/// Limbs of a `BigNat`: 2816 bits. The widest values are 768 digits (2552
/// bits), 5^1092 (2536 bits), and either of them shifted to the other's
/// length plus one bit.
eval BIG_LIMBS: usize = 88

/// Significant digits the exact path keeps. A value halfway between two
/// floats has at most 767 significant digits, so a nonzero digit past 768
/// only says "above the truncation", which the sticky flag carries.
eval BIG_MAX_DIGITS: i32 = 768

/// An unsigned integer: `w[0 .. n)` least significant first, `w[n - 1]`
/// nonzero, and `n == 0` for zero. Limbs at and above `n` are unspecified.
struct BigNat {
    var w: [u32; 88]
    var n: usize
}

/// a = a * m + add.
fn big_mul_add(a: *BigNat, m: u32, add: u32) {
    var carry: u64 = add
    for var i: usize = 0; i < a->n; ++i {
        var t = (a->w[i] as u64) * (m as u64) + carry
        a->w[i] = t as u32
        carry   = t >> 32
    }

    if carry != 0 {
        a->w[a->n] = carry as u32
        a->n += 1
    }
}

/// a = a * 5^e.
fn big_mul_pow5(a: *BigNat, e: u32) {
    var left = e
    while left >= 13 {
        big_mul_add(a, 1220703125, 0) // 5^13, the largest power in a limb
        left -= 13
    }

    var m: u32 = 1
    while left > 0 {
        m = m * 5
        left -= 1
    }

    big_mul_add(a, m, 0)
}

/// The number of bits in `a`; 0 for zero.
fn big_bitlen(a: *const BigNat) -> i32 {
    if a->n == 0 {
        return 0
    }

    return (a->n as i32) * 32 - (__builtin_clz(a->w[a->n - 1]) as i32)
}

/// a = a * 2^k.
fn big_shl(a: *BigNat, k: i32) {
    if k <= 0 || a->n == 0 {
        return
    }

    var ws = (k >> 5) as usize
    var bs = (k & 31) as u32
    var i  = a->n
    if bs != 0 {
        var top = a->w[a->n - 1] >> (32 - bs)
        if top != 0 {
            a->w[a->n + ws] = top
        }

        while i > 0 {
            i -= 1
            var v = a->w[i] << bs
            if i > 0 {
                v = v | (a->w[i - 1] >> (32 - bs))
            }

            a->w[i + ws] = v
        }

        a->n = a->n + ws + (if top != 0 => 1usize else => 0usize)
    } else {
        while i > 0 {
            i -= 1
            a->w[i + ws] = a->w[i]
        }

        a->n = a->n + ws
    }

    for var j: usize = 0; j < ws; ++j {
        a->w[j] = 0
    }
}

/// Negative, zero or positive as a is below, equal to or above b.
fn big_cmp(a: *const BigNat, b: *const BigNat) -> i32 {
    if a->n != b->n {
        return if a->n < b->n => -1 else => 1
    }

    var i = a->n
    while i > 0 {
        i -= 1
        if a->w[i] != b->w[i] {
            return if a->w[i] < b->w[i] => -1 else => 1
        }
    }

    return 0
}

/// a = a - b.
///
/// **Precondition:** a >= b.
fn big_sub(a: *BigNat, b: *const BigNat) {
    var borrow: u64 = 0
    for var i: usize = 0; i < a->n; ++i {
        var bw: u64 = if i < b->n => b->w[i] else => 0u64
        var t       = (a->w[i] as u64) - bw - borrow
        a->w[i] = t as u32
        borrow  = (t >> 32) & 1
    }

    while a->n > 0 && a->w[a->n - 1] == 0 {
        a->n -= 1
    }
}

/// The top 64 bits of `a`, left-aligned. `*sticky` is set when a set bit
/// lies below them.
///
/// **Precondition:** a is nonzero and `len` is its bit length.
fn big_top64(a: *const BigNat, len: i32, sticky: *bool) -> u64 {
    if len <= 64 {
        var v: u64 = a->w[0]
        if a->n > 1 {
            v = v | ((a->w[1] as u64) << 32)
        }

        return v << ((64 - len) as u32)
    }

    var sh = len - 64
    var wi = (sh >> 5) as usize
    var bo = (sh & 31) as u32
    for var j: usize = 0; j < wi; ++j {
        if a->w[j] != 0 {
            *sticky = true
        }
    }

    var v = ((a->w[wi] as u64) >> bo) | ((a->w[wi + 1] as u64) << (32 - bo))
    if bo != 0 {
        if (a->w[wi] & ((1u32 << bo) - 1)) != 0 {
            *sticky = true
        }

        // The top bit is in limb wi + 2 exactly when bo is nonzero.
        v = v | ((a->w[wi + 2] as u64) << (64 - bo))
    }

    return v
}

/// The bit pattern of `m * 2^e` rounded to nearest, ties to even, where the
/// exact value lies in `[m, m + 1) * 2^e` and is `m * 2^e` itself only when
/// `sticky` is false.
///
/// **Precondition:** the top bit of `m` is set.
fn round_to_bits(m: u64, e: i64, sticky: bool, single: bool) -> u64 {
    var mant_bits: i32 = if single => 23 else => 52
    var min_e2:    i64 = if single => -126 else => -1022
    var bias:      i64 = if single => 127 else => 1023
    var inf:       u64 = (if single => 0xFFu64 else => 0x7FFu64) << (mant_bits as u32)

    var e2 = e + 63 // the exponent of the top bit
    if e2 > 2000 {
        return inf
    }

    if e2 < -2000 {
        return 0
    }

    // Bits dropped: the ones below the precision, and below the smallest
    // subnormal's unit for a subnormal result.
    var shift: i64 = (63 - mant_bits)
    var base:  u64 = ((e2 + bias - 1) as u64) << (mant_bits as u32)
    if e2 < min_e2 {
        shift = shift + (min_e2 - e2)
        base  = 0
    }

    if shift > 64 {
        return 0
    }

    var kept: u64 = 0
    var rest: u64 = m
    if shift < 64 {
        kept = m >> (shift as u32)
        rest = m & ((1u64 << (shift as u32)) - 1)
    }

    var half: u64 = 1u64 << ((shift - 1) as u32)
    if rest > half || (rest == half && (sticky || (kept & 1) != 0)) {
        kept += 1
    }

    // kept carries the implicit bit, so adding it to the exponent field
    // below also handles the carry into the next binade.
    var bits = base + kept
    return if bits > inf => inf else => bits
}

/// The bit pattern of the float nearest the decimal number whose integer
/// digits are `p[int_from .. int_to)`, fraction digits `p[frac_from ..
/// frac_to)` and exponent `ex`. Exact for every input.
@cold_path @no_inline fn exact_decimal(p:         unsafe *const u8,
                                       int_from:  usize,
                                       int_to:    usize,
                                       frac_from: usize,
                                       frac_to:   usize,
                                       ex:        i64,
                                       single:    bool) -> u64 {
    var d: BigNat
    d.n = 0
    var nd:        i32 = 0     // significant digits taken
    var dropped:   i64 = 0     // integer digits not taken
    var fracn:     i64 = 0     // fraction digits taken, leading zeros included
    var sticky         = false
    var chunk:     u32 = 0
    var chunk_len: i32 = 0

    for var i: usize = int_from; i < int_to; ++i {
        var c = (p[i] - 48) as u32
        if nd < BIG_MAX_DIGITS {
            if nd != 0 || c != 0 {
                chunk = chunk * 10 + c
                chunk_len += 1
                nd += 1
                if chunk_len == 9 {
                    big_mul_add(&d, 1000000000, chunk)
                    chunk     = 0
                    chunk_len = 0
                }
            }
        } else {
            dropped += 1
            if c != 0 {
                sticky = true
            }
        }
    }

    for var i: usize = frac_from; i < frac_to; ++i {
        var c = (p[i] - 48) as u32
        if nd < BIG_MAX_DIGITS {
            fracn += 1
            if nd != 0 || c != 0 {
                chunk = chunk * 10 + c
                chunk_len += 1
                nd += 1
                if chunk_len == 9 {
                    big_mul_add(&d, 1000000000, chunk)
                    chunk     = 0
                    chunk_len = 0
                }
            }
        } else if c != 0 {
            sticky = true
        }
    }

    if chunk_len != 0 {
        var scale: u32 = 1
        for var i: i32 = 0; i < chunk_len; ++i {
            scale = scale * 10
        }

        big_mul_add(&d, scale, chunk)
    }

    var inf: u64 = if single => 0x7F800000u64 else => 0x7FF0000000000000u64
    if nd == 0 {
        return 0
    }

    // The value is d * 10^e10 and lies in [10^lead, 10^(lead + 1)). Beyond
    // these bounds it is above every finite f64 or below half the smallest
    // subnormal, and inside them the integers below fit a BigNat.
    var e10  = ex + dropped - fracn
    var lead = e10 + (nd as i64) - 1
    if lead >= 310 {
        return inf
    }

    if lead <= -326 {
        return 0
    }

    var m: u64 = 0
    var e: i64 = 0
    if e10 >= 0 {
        // An integer: its top 64 bits.
        big_mul_pow5(&d, e10 as u32)
        var len = big_bitlen(const &d)
        m = big_top64(const &d, len, &sticky)
        e = (len as i64) - 64 + e10
    } else {
        // d / 5^n * 2^-n: scale so that b <= d < 2b, then 64 quotient bits
        // by shift and subtract.
        var b: BigNat
        b.n    = 1
        b.w[0] = 1
        big_mul_pow5(&b, (0 - e10) as u32)
        var s = big_bitlen(const &b) - big_bitlen(const &d)
        if s >= 0 {
            big_shl(&d, s)
        } else {
            big_shl(&b, 0 - s)
        }

        if big_cmp(const &d, const &b) < 0 {
            big_shl(&d, 1)
            s += 1
        }

        for var i: i32 = 0; i < 64; ++i {
            m = m << 1
            if big_cmp(const &d, const &b) >= 0 {
                big_sub(&d, const &b)
                m = m | 1
            }

            big_shl(&d, 1)
        }

        if d.n != 0 {
            sticky = true
        }

        e = e10 - 63 - (s as i64)
    }

    return round_to_bits(m, e, sticky, single)
}

// --- text to value: scanning ------------------------------------------------------

/// Records the failure and returns the bits every failed parse returns.
@cold_path @no_inline fn float_fail(@inout err: ParseError,
                                    at:         usize,
                                    kind:       ParseErrorKind) -> u64 {
    err.at   = if at > 0xFFFFFFFF => 0xFFFFFFFFu32 else => at as u32
    err.kind = kind
    return 0
}

/// Whether `p[i .. i + 3)` is the ASCII word `a b c`, in either case.
inline fn word3(p: unsafe *const u8, i: usize, a: u8, b: u8, c: u8) -> bool {
    return (p[i] | 32) == a && (p[i + 1] | 32) == b && (p[i + 2] | 32) == c
}

/// `inf`, `infinity` or `nan` at `p[i .. n)`, the whole of the rest.
@cold_path @no_inline fn parse_special(p:          unsafe *const u8,
                                       i:          usize,
                                       n:          usize,
                                       sign:       u64,
                                       single:     bool,
                                       @inout err: ParseError) -> u64 {
    if n - i >= 3 && word3(p, i, 105, 110, 102) {
        var j = i + 3
        if n - j >= 5
            && word3(p, j, 105, 110, 105)
            && (p[j + 3] | 32) == 116
            && (p[j + 4] | 32) == 121 {
            j += 5
        }

        if j < n {
            return float_fail(&err, j, ParseErrorKind::Trailing)
        }

        return sign | (if single => 0x7F800000u64 else => 0x7FF0000000000000u64)
    }

    if n - i >= 3 && word3(p, i, 110, 97, 110) {
        if i + 3 < n {
            return float_fail(&err, i + 3, ParseErrorKind::Trailing)
        }

        return sign | (if single => 0x7FC00000u64 else => 0x7FF8000000000000u64)
    }

    return float_fail(&err, i, ParseErrorKind::InvalidChar)
}

/// `w * 10^q` for the first 19 significant digits of a number with more
/// than 19 digits: `truncated` when a nonzero digit is left out of `w`.
struct Leading19 {
    var w:         u64
    var q:         i64
    var truncated: bool
}

/// The digits `p[int_from .. int_to)` `.` `p[frac_from .. frac_to)`, times
/// `10^ex`, cut to their first 19 significant digits. For texts of more
/// than 19 digits, leading zeros included, where `w` accumulated by the
/// scan may have wrapped.
@cold_path @no_inline fn leading19(p:         unsafe *const u8,
                                   int_from:  usize,
                                   int_to:    usize,
                                   frac_from: usize,
                                   frac_to:   usize,
                                   ex:        i64) -> Leading19 {
    var r       = Leading19 { w: 0, q: ex, truncated: false }
    var nd: i32 = 0
    for var i = int_from; i < int_to; ++i {
        var d: u64 = p[i] - 48
        if nd < 19 {
            r.w = r.w * 10 + d
            if r.w != 0 {
                nd += 1
            }
        } else {
            r.q += 1
            if d != 0 {
                r.truncated = true
            }
        }
    }

    for var j = frac_from; j < frac_to; ++j {
        var d: u64 = p[j] - 48
        if nd < 19 {
            r.w = r.w * 10 + d
            r.q -= 1
            if r.w != 0 {
                nd += 1
            }
        } else if d != 0 {
            r.truncated = true
        }
    }

    return r
}

/// Takes the digits at `p[from .. n)` into `w`, eight at a time while eight are
/// left; returns where they end. `w` wraps past 19 digits, which the caller
/// detects from the count.
inline fn scan_digits(p: unsafe *const u8, from: usize, n: usize, @inout w: u64) -> usize {
    var i = from
    while n - i >= 8 {
        var eight = read_le64(unsafe p + i)
        if !is_eight_digits(eight) {
            break
        }

        w = w * 100000000 + eight_digits_value(eight)
        i += 8
    }

    while i < n {
        var d = p[i] - 48
        if d > 9 {
            break
        }

        w = w * 10 + (d as u64)
        i += 1
    }

    return i
}

/// 10^0 .. 10^22, every one exact in an f64.
priv static const NUMTEXT_EXACT_POW10_F64: [f64; 23] = [
    1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,
    1e8,  1e9,  1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
    1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]

/// 10^0 .. 10^10, every one exact in an f32.
priv static const NUMTEXT_EXACT_POW10_F32: [f32; 11] = [
    1e0, 1e1, 1e2,  1e3, 1e4, 1e5, 1e6, 1e7,
    1e8, 1e9, 1e10,
]

/// Whether the float unit rounds each f32 and f64 operation once, to the
/// type: true for the SSE2 unit every x86-64 has and for AArch64, false for
/// x87 (excess precision) and soft-float targets, which keep to integers.
eval FLOAT_OPS_EXACT: bool = defined!(__x86_64__) || defined!(__aarch64__)

/// `w * 10^q` rounded once, when that is one float operation on exact
/// operands (W. D. Clinger, "How to Read Floating Point Numbers
/// Accurately"): `w` is exact in `F` and so is `10^|q|`, so the product or
/// quotient is correctly rounded under the default rounding mode. Returns
/// the bit pattern, or `FLOAT_UNDECIDED` when `w` or `q` is out of reach.
inline fn <F> clinger(w: u64, q: i64) -> u64 {
    eval if FLOAT_OPS_EXACT {
        eval if __builtin_is_same<F, f32>() {
            if w <= (1u64 << 24) && q >= -10 && q <= 10 {
                var v = w as f32
                if q < 0 {
                    v = v / NUMTEXT_EXACT_POW10_F32[(0 - q) as usize]
                } else {
                    v = v * NUMTEXT_EXACT_POW10_F32[q as usize]
                }

                return __builtin_bitcast<u32, f32>(v)
            }
        } else {
            if w <= (1u64 << 53) && q >= -22 && q <= 22 {
                var v = w as f64
                if q < 0 {
                    v = v / NUMTEXT_EXACT_POW10_F64[(0 - q) as usize]
                } else {
                    v = v * NUMTEXT_EXACT_POW10_F64[q as usize]
                }

                return __builtin_bitcast<u64, f64>(v)
            }
        }
    }

    return FLOAT_UNDECIDED
}

/// The bit pattern (an f32's in the low word when `single`) of the float
/// nearest the number `p[0 .. n)` spells, for `F` f64 or f32 (as for
/// `eisel_lemire`).
///
/// The digits accumulate without a count and the count comes from where
/// they end; past 19 of them `leading19` takes the significant ones again.
/// Then: one float operation when that is exact (`clinger`), Eisel-Lemire
/// when the 128-bit product decides, exact arithmetic otherwise.
fn <F> parse_float_bits(p: unsafe *const u8, n: usize, @inout err: ParseError) -> u64 {
    var single = __builtin_is_same<F, f32>()
    if n == 0 {
        return float_fail(&err, 0, ParseErrorKind::Empty)
    }

    var i:    usize = 0
    var sign: u64   = 0
    if p[0] == 43 || p[0] == 45 {
        if n == 1 {
            return float_fail(&err, 0, ParseErrorKind::InvalidChar)
        }

        if p[0] == 45 {
            sign = if single => 0x80000000u64 else => 0x8000000000000000u64
        }

        i = 1
    }

    var first = i
    if (p[i] - 48) > 9 && p[i] != 46 {
        return parse_special(p, i, n, sign, single, &err)
    }

    var w:        u64 = 0
    var int_from      = i
    var int_to        = scan_digits(p, i, n, &w)
    var frac_from     = int_to
    var frac_to       = int_to
    i = int_to
    if i < n && p[i] == 46 {
        frac_from = i + 1
        frac_to   = scan_digits(p, frac_from, n, &w)
        if int_to == int_from && frac_to == frac_from {
            return float_fail(&err, i, ParseErrorKind::InvalidChar)
        }

        i = frac_to
    }

    // An exponent needs at least one digit; otherwise the `e` is trailing.
    var ex: i64 = 0
    if i < n && (p[i] | 32) == 101 {
        var j    = i + 1
        var eneg = false
        if j < n && (p[j] == 43 || p[j] == 45) {
            eneg = p[j] == 45
            j += 1
        }

        if j < n && (p[j] - 48) <= 9 {
            while j < n {
                var c = p[j] - 48
                if c > 9 {
                    break
                }

                // Saturates far beyond any exponent that matters.
                if ex < 100000000000000000 {
                    ex = ex * 10 + (c as i64)
                }

                j += 1
            }

            if eneg {
                ex = 0 - ex
            }

            i = j
        }
    }

    if i < n {
        return float_fail(&err, i, ParseErrorKind::Trailing)
    }

    var q         = ex - ((frac_to - frac_from) as i64)
    var truncated = false
    if (int_to - int_from) + (frac_to - frac_from) > 19 {
        var r = leading19(p, int_from, int_to, frac_from, frac_to, ex)
        w         = r.w
        q         = r.q
        truncated = r.truncated
    }

    if w == 0 {
        return sign
    }

    var bits = FLOAT_UNDECIDED
    if !truncated {
        bits = clinger<F>(w, q)
    }

    if bits == FLOAT_UNDECIDED {
        bits = eisel_lemire<F>(w, q)
        // With digits cut off the value lies strictly between w and w + 1;
        // it is settled only when both round to the same float.
        if truncated && bits != FLOAT_UNDECIDED && eisel_lemire<F>(w + 1, q) != bits {
            bits = FLOAT_UNDECIDED
        }
    }

    if bits == FLOAT_UNDECIDED {
        bits = exact_decimal(
            p,
            int_from,
            int_to,
            frac_from,
            frac_to,
            ex,
            single,
        )
    }

    if bits >= (if single => 0x7F800000u64 else => 0x7FF0000000000000u64) {
        return float_fail(&err, first, ParseErrorKind::Overflow)
    }

    return sign | bits
}

/// Parses `[+-](digits[.digits] | .digits)[(e|E)[+-]digits]`, `[+-]inf`,
/// `[+-]infinity` or `[+-]nan` (the words in either case) as the nearest
/// f64, ties to even.
///
/// A finite number too large for the type is `Overflow`; one too small
/// rounds to zero.
///
/// **Precondition:** `p` is valid for reads of `n` bytes; `err` is clear
/// (kind `None`, at 0), and is written only on failure.
prot inline fn parse_f64(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f64 {
    var bits     = parse_float_bits<f64>(p, n, &err)
    var v:   f64 = 0.0
    unsafe {
        __builtin_copy(&v as unsafe *u8, &bits as unsafe *const u8, 8)
    }

    return v
}

/// The f32 counterpart of `parse_f64`; the text is rounded once, to f32.
prot inline fn parse_f32(p: unsafe *const u8, n: usize, @inout err: ParseError) -> f32 {
    var bits     = parse_float_bits<f32>(p, n, &err) as u32
    var v:   f32 = 0.0
    unsafe {
        __builtin_copy(&v as unsafe *u8, &bits as unsafe *const u8, 4)
    }

    return v
}
