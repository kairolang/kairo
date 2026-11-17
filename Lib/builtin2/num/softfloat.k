/// --- The Kairo Project ------------------ Lib/builtin/num/softfloat.k --- ///
///
///   \brief The software binary-float engine behind `f256` and `f512`: one
///          implementation for every IEEE-754-shaped binary format up to
///          512 bits, parameterised by width at run time (SfFmt).
///
///   \detail
///     LLVM has no type wider than fp128, so f256 and f512 are classes
///     (num/f256.k, num/f512.k) whose every operation lands here. Nothing
///     in this file knows a width: an SfFmt names the encoding (total and
///     exponent bits) and the same code serves binary16 through binary512.
///     That is also how it is tested: instantiated at 32, 64 and 128 bits it
///     must agree bit for bit with the native float, f32, f64 and f128,
///     which is the one check on the engine that no oracle can fake.
///
///     Arithmetic is on little-endian arrays of u32 limbs (SfW), products
///     and quotients in u64. No u128 and no wider _BitInt appears: those
///     are fine on 64-bit targets, but a 64/32 or 128/64 division on a
///     32-bit one is a compiler-rt call that not every sysroot ships.
///
///     Semantics, every operation:
///       - round to nearest, ties to even, once, from the exact result;
///       - signed zeros, subnormals, infinities;
///       - a NaN result is the canonical quiet NaN: sign 0, exponent all
///         ones, the top fraction bit alone. NaN payloads are not
///         propagated (IEEE allows either); neg, abs and copysign are bit
///         operations and keep the operand's bits, NaN or not;
///       - no status flags and no traps; a signaling NaN is a NaN.
///
///     The one rounding routine is round_pack: every result (sum, product,
///     quotient, root, conversion, decimal parse) is first computed as an
///     integer M and an exponent e with value M * 2^e, exact or with the
///     bits below some position collapsed into M's lowest bit ("jamming",
///     SoftFloat's term). Jamming is exact for rounding as long as the
///     collapsed bit sits at least two places below the rounding position,
///     which every caller guarantees by keeping three or more extra bits.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Limbs in a work buffer: 52 x 32 = 1664 bits. The widest user is fma at
/// binary512, whose window is 3 * 489 + 8 = 1475 bits; a binary512 product
/// is 978 and a quotient's numerator 980.
pub eval SFW_LIMBS: i32 = 52

/// A little-endian multi-limb unsigned integer (limb 0 is the least
/// significant). Every routine takes the limb count it may touch.
pub struct SfW {
    /// The limbs, least significant first.
    pub var w: [u32; 52]
}

/// One binary interchange-style encoding: sign, `ebits` of biased
/// exponent, `mbits` of fraction with a hidden leading bit.
pub struct SfFmt {
    /// Total bits.
    pub var nbits: i32
    /// Exponent field width.
    pub var ebits: i32
    /// Stored fraction bits (precision - 1).
    pub var mbits: i32
    /// Significand bits, the hidden one included.
    pub var prec: i32
    /// Exponent bias.
    pub var bias: i32
    /// 1 - bias: the smallest normal exponent.
    pub var emin: i32
    /// The all-ones exponent field.
    pub var emask: i32
    /// u32 limbs of the encoding.
    pub var nw: i32
}

/// The format with `nbits` total and `ebits` exponent bits.
pub fn sf_fmt(nbits: i32, ebits: i32) -> SfFmt {
    var f = SfFmt {
        nbits: nbits,
        ebits: ebits,
        mbits: 0,
        prec:  0,
        bias:  0,
        emin:  0,
        emask: 0,
        nw:    0,
    }

    f.mbits = nbits - 1 - ebits
    f.prec  = f.mbits + 1
    f.bias  = (1 << ((ebits - 1) as u32)) - 1
    f.emin  = 1 - f.bias
    f.emask = (1 << (ebits as u32)) - 1
    f.nw    = (nbits + 31) / 32
    return f
}

/// What a value is, as classify reports it.
pub eval SF_ZERO: i32 = 0
/// A normal or subnormal nonzero value.
pub eval SF_FINITE: i32 = 1 ///< normal or subnormal, nonzero
/// An infinity.
pub eval SF_INF: i32 = 2
/// A NaN.
pub eval SF_NAN: i32 = 3

/// An unpacked value: `m * 2^e` with the hidden bit made explicit.
pub struct SfU {
    /// SF_ZERO, SF_FINITE, SF_INF or SF_NAN.
    pub var cls: i32 = 0
    /// The sign bit.
    pub var neg: bool = false
    /// The exponent of m's lowest bit.
    pub var e: i32 = 0
    /// The significand, the hidden bit explicit.
    pub var m: SfW
}

// === limb primitives ========================================================
//
// Every shift count is checked against 32 before it is used: a Kairo shift
// takes its count modulo the width, so `x << 32` on a u32 is x, not 0.

/// Zeroes limbs [0, n).
pub fn sfw_zero(a: *SfW, n: i32) {
    for var i: i32 = 0; i < n; ++i {
        a->w[i] = 0
    }
}

/// Copies n limbs from s to d.
pub fn sfw_copy(d: *SfW, s: *const SfW, n: i32) {
    for var i: i32 = 0; i < n; ++i {
        d->w[i] = s->w[i]
    }
}

/// Whether limbs [0, n) are all zero.
pub fn sfw_is_zero(a: *const SfW, n: i32) -> bool {
    for var i: i32 = 0; i < n; ++i {
        if a->w[i] != 0 {
            return false
        }
    }

    return true
}

/// Leading zero bits of x; 32 for 0.
pub fn sf_clz32(x: u32) -> i32 {
    if x == 0 {
        return 32
    }

    var n: i32 = 0
    var v      = x
    if (v & 0xFFFF0000) == 0 {
        n += 16
        v = v << 16
    }

    if (v & 0xFF000000) == 0 {
        n += 8
        v = v << 8
    }

    if (v & 0xF0000000) == 0 {
        n += 4
        v = v << 4
    }

    if (v & 0xC0000000) == 0 {
        n += 2
        v = v << 2
    }

    if (v & 0x80000000) == 0 {
        n += 1
    }

    return n
}

/// Index of the highest set bit plus one; 0 for zero.
pub fn sfw_bitlen(a: *const SfW, n: i32) -> i32 {
    var i = n - 1
    while i >= 0 {
        if a->w[i] != 0 {
            return i * 32 + 32 - sf_clz32(a->w[i])
        }

        i -= 1
    }

    return 0
}

/// Bit i of a (0 or 1).
pub fn sfw_bit(a: *const SfW, i: i32) -> u32 {
    return a->w[i >> 5] >> ((i & 31) as u32) & 1
}

/// Whether any of bits [0, k) is set.
pub fn sfw_any_below(a: *const SfW, k: i32) -> bool {
    var full = k >> 5
    for var i: i32 = 0; i < full; ++i {
        if a->w[i] != 0 {
            return true
        }
    }

    var r = k & 31
    if r != 0 {
        var mask: u32 = (1 << (r as u32)) - 1
        if (a->w[full] & mask) != 0 {
            return true
        }
    }

    return false
}

/// a <<= k over n limbs; bits shifted past limb n-1 are lost.
pub fn sfw_shl(a: *SfW, n: i32, k: i32) {
    if k <= 0 {
        return
    }

    var ws = k >> 5
    var bs = (k & 31) as u32
    var i  = n - 1
    while i >= 0 {
        var v:  u32 = 0
        var src     = i - ws
        if src >= 0 {
            v = a->w[src] << bs
            if bs != 0 && src - 1 >= 0 {
                v = v | a->w[src - 1] >> 32 - bs
            }
        }

        a->w[i] = v
        i -= 1
    }
}

/// a >>= k over n limbs. Returns whether a set bit was shifted out.
pub fn sfw_shr(a: *SfW, n: i32, k: i32) -> bool {
    if k <= 0 {
        return false
    }

    var lost = sfw_any_below(a, if k < n * 32 => k else => n * 32)
    var ws   = k >> 5
    var bs   = (k & 31) as u32
    for var i: i32 = 0; i < n; ++i {
        var v:  u32 = 0
        var src     = i + ws
        if src < n {
            v = a->w[src] >> bs
            if bs != 0 && src + 1 < n {
                v = v | a->w[src + 1] << 32 - bs
            }
        }

        a->w[i] = v
    }

    return lost
}

/// a >>= k, the lost bits ORed into bit 0 (a "jam").
pub fn sfw_shr_jam(a: *SfW, n: i32, k: i32) {
    if sfw_shr(a, n, k) {
        a->w[0] = a->w[0] | 1
    }
}

/// a += b over n limbs; returns the carry out.
pub fn sfw_add(a: *SfW, b: *const SfW, n: i32) -> u32 {
    var c: u64 = 0
    for var i: i32 = 0; i < n; ++i {
        var s = (a->w[i] as u64) + (b->w[i] as u64) + c
        a->w[i] = s as u32
        c       = s >> 32
    }

    return c as u32
}

/// a -= b over n limbs; returns the borrow out.
pub fn sfw_sub(a: *SfW, b: *const SfW, n: i32) -> u32 {
    var br: u64 = 0
    for var i: i32 = 0; i < n; ++i {
        var s = (a->w[i] as u64) - (b->w[i] as u64) - br
        a->w[i] = s as u32
        br      = s >> 32 & 1
    }

    return br as u32
}

/// -1, 0 or 1 as a <, ==, > b over n limbs.
pub fn sfw_cmp(a: *const SfW, b: *const SfW, n: i32) -> i32 {
    var i = n - 1
    while i >= 0 {
        if a->w[i] != b->w[i] {
            return if a->w[i] < b->w[i] => -1 else => 1
        }

        i -= 1
    }

    return 0
}

/// a += x << (32 * at) (x a single limb), carrying through n limbs.
pub fn sfw_add_word(a: *SfW, n: i32, x: u32, at: i32) {
    var c = x as u64
    var i = at
    while c != 0 && i < n {
        var s = (a->w[i] as u64) + c
        a->w[i] = s as u32
        c       = s >> 32
        i += 1
    }
}

/// a = a * x + y over n limbs; returns the limb carried out.
pub fn sfw_mul_small(a: *SfW, n: i32, x: u32, y: u32) -> u32 {
    var c = y as u64
    for var i: i32 = 0; i < n; ++i {
        var p = (a->w[i] as u64) * (x as u64) + c
        a->w[i] = p as u32
        c       = p >> 32
    }

    return c as u32
}

/// r = a * b; r gets na + nb limbs and must not alias a or b.
pub fn sfw_mul(r: *SfW, a: *const SfW, na: i32, b: *const SfW, nb: i32) {
    sfw_zero(r, na + nb)
    for var i: i32 = 0; i < na; ++i {
        var ai = a->w[i] as u64
        if ai == 0 {
            continue
        }

        var c: u64 = 0
        for var j: i32 = 0; j < nb; ++j {
            var p = ai * (b->w[j] as u64) + (r->w[i + j] as u64) + c
            r->w[i + j] = p as u32
            c           = p >> 32
        }

        r->w[i + nb] = c as u32
    }
}

/// Limbs in use (at least 1).
pub fn sfw_used(a: *const SfW, n: i32) -> i32 {
    var k = n
    while k > 1 && a->w[k - 1] == 0 {
        k -= 1
    }

    return k
}

/// q = u / v, r = u % v (Knuth, TAOCP 4.3.1 Algorithm D, base 2^32).
/// u has nu limbs, v has nv; q gets nu limbs, r gets nv. v must be nonzero.
/// u and v are not modified.
pub fn sfw_divmod(q: *SfW, r: *SfW, u: *const SfW, nu: i32, v: *const SfW, nv: i32) {
    var n = sfw_used(v, nv)
    var m = sfw_used(u, nu)
    sfw_zero(q, nu)
    sfw_zero(r, nv)
    if m < n {
        sfw_copy(r, u, m)
        return
    }

    if n == 1 {
        var d        = v->w[0] as u64
        var rem: u64 = 0
        var i        = m - 1
        while i >= 0 {
            var cur = rem << 32 | (u->w[i] as u64)
            q->w[i] = (cur / d) as u32
            rem     = cur % d
            i -= 1
        }

        r->w[0] = rem as u32
        return
    }

    // D1: normalise so the divisor's top limb has its high bit set.
    var s       = sf_clz32(v->w[n - 1])
    var vn: SfW
    var un: SfW
    sfw_zero(&vn, n)
    sfw_zero(&un, m + 1)
    sfw_copy(&vn, v, n)
    sfw_copy(&un, u, m)
    sfw_shl(&vn, n, s)
    sfw_shl(&un, m + 1, s)
    var vtop  = vn.w[n - 1] as u64
    var vnext = vn.w[n - 2] as u64
    var j     = m - n
    while j >= 0 {
        // D3: estimate qhat from the top two limbs, correct it at most twice.
        var num  = (un.w[j + n] as u64) << 32 | (un.w[j + n - 1] as u64)
        var qhat = num / vtop
        var rhat = num % vtop
        while qhat >= 0x100000000 || qhat * vnext > (rhat << 32 | (un.w[j + n - 2] as u64)) {
            qhat -= 1
            rhat += vtop
            if rhat >= 0x100000000 {
                break
            }
        }

        // D4: multiply and subtract.
        var borrow: u64 = 0
        var carry:  u64 = 0
        for var i: i32 = 0; i < n; ++i {
            var p = qhat * (vn.w[i] as u64) + carry
            carry = p >> 32
            var t = (un.w[i + j] as u64) - (p & 0xFFFFFFFF) - borrow
            un.w[i + j] = t as u32
            borrow      = t >> 32 & 1
        }

        var t2 = (un.w[j + n] as u64) - carry - borrow
        un.w[j + n] = t2 as u32
        // D6: the estimate was one too large; add the divisor back.
        if (t2 >> 32 & 1) != 0 {
            qhat -= 1
            var c: u64 = 0
            for var i: i32 = 0; i < n; ++i {
                var sm = (un.w[i + j] as u64) + (vn.w[i] as u64) + c
                un.w[i + j] = sm as u32
                c           = sm >> 32
            }

            un.w[j + n] = ((un.w[j + n] as u64) + c) as u32
        }

        q->w[j] = qhat as u32
        j -= 1
    }

    // D8: the remainder, unnormalised.
    sfw_copy(r, &un, n)
    sfw_shr(r, n, s)
}

/// floor(sqrt(a)) into r over n limbs; returns whether it was inexact.
/// Digit by digit, two bits of a per bit of the root.
pub fn sfw_isqrt(r: *SfW, a: *const SfW, n: i32) -> bool {
    var rem: SfW
    var bit: SfW
    var t:   SfW
    sfw_copy(&rem, a, n)
    sfw_zero(r, n)
    sfw_zero(&bit, n)
    var top = sfw_bitlen(a, n)
    if top == 0 {
        return false
    }

    var b = top - 1 & -2
    bit.w[b >> 5] = (1 as u32) << ((b & 31) as u32)
    while b >= 0 {
        // t = r + bit; if rem >= t { rem -= t; r = (r >> 1) + bit } else r >>= 1
        sfw_copy(&t, r, n)
        sfw_add(&t, &bit, n)
        if sfw_cmp(&rem, &t, n) >= 0 {
            sfw_sub(&rem, &t, n)
            sfw_shr(r, n, 1)
            sfw_add(r, &bit, n)
        } else {
            sfw_shr(r, n, 1)
        }

        bit.w[b >> 5] = 0
        b -= 2
        if b >= 0 {
            bit.w[b >> 5] = (1 as u32) << ((b & 31) as u32)
        }
    }

    return !sfw_is_zero(&rem, n)
}

// === encode / decode ========================================================

/// The exponent field of a packed value.
fn field_(f: SfFmt, a: *const SfW) -> i32 {
    var v: i32 = 0
    for var k: i32 = 0; k < f.ebits; ++k {
        v = v | (sfw_bit(a, f.mbits + k) as i32) << (k as u32)
    }

    return v
}

/// The sign bit of an encoding.
pub fn sf_sign(f: SfFmt, a: *const SfW) -> bool {
    return sfw_bit(a, f.nbits - 1) != 0
}

fn frac_zero_(f: SfFmt, a: *const SfW) -> bool {
    return !sfw_any_below(a, f.mbits)
}

/// Classify a packed value: SF_ZERO, SF_FINITE, SF_INF or SF_NAN.
pub fn sf_class(f: SfFmt, a: *const SfW) -> i32 {
    var e = field_(f, a)
    if e == f.emask {
        return if frac_zero_(f, a) => SF_INF else => SF_NAN
    }

    if e == 0 && frac_zero_(f, a) {
        return SF_ZERO
    }

    return SF_FINITE
}

/// Whether a finite nonzero value is subnormal.
pub fn sf_is_subnormal(f: SfFmt, a: *const SfW) -> bool {
    return field_(f, a) == 0 && !frac_zero_(f, a)
}

/// Unpack: value = m * 2^e, m with the hidden bit when normal.
pub fn sf_unpack(f: SfFmt, a: *const SfW, u: *SfU) {
    u->neg = sf_sign(f, a)
    u->cls = sf_class(f, a)
    sfw_zero(&u->m, SFW_LIMBS)
    sfw_copy(&u->m, a, f.nw)
    // Keep the fraction only.
    var full = f.mbits >> 5
    var r    = f.mbits & 31
    if r != 0 {
        u->m.w[full] = u->m.w[full] & ((1 as u32) << (r as u32)) - 1
        full += 1
    }

    for var i: i32 = full; i < f.nw; ++i {
        u->m.w[i] = 0
    }

    var e = field_(f, a)
    if e == 0 {
        u->e = f.emin - f.mbits
    } else {
        u->m.w[f.mbits >> 5] = u->m.w[f.mbits >> 5] | (1 as u32) << ((f.mbits & 31) as u32)
        u->e                 = e - f.bias - f.mbits
    }
}

/// out = a zero of the given sign.
pub fn sf_set_zero(f: SfFmt, out: *SfW, neg: bool) {
    sfw_zero(out, f.nw)
    if neg {
        out->w[f.nbits - 1 >> 5] = (1 as u32) << ((f.nbits - 1 & 31) as u32)
    }
}

/// Adds `v << at` into out (v small and nonnegative).
fn add_at_(out: *SfW, n: i32, v: u32, at: i32) {
    var lo = (v as u64) << ((at & 31) as u64)
    sfw_add_word(out, n, lo as u32, at >> 5)
    sfw_add_word(out, n, (lo >> 32) as u32, (at >> 5) + 1)
}

/// out = an infinity of the given sign.
pub fn sf_set_inf(f: SfFmt, out: *SfW, neg: bool) {
    sf_set_zero(f, out, neg)
    add_at_(out, f.nw, f.emask as u32, f.mbits)
}

/// out = the canonical quiet NaN.
pub fn sf_set_nan(f: SfFmt, out: *SfW) {
    sf_set_zero(f, out, false)
    add_at_(out, f.nw, f.emask as u32, f.mbits)
    add_at_(out, f.nw, 1, f.mbits - 1)
}

/// Rounds m * 2^e (m over nm limbs, possibly jammed, consumed) to nearest
/// even and encodes it with sign `neg` into out. The heart of every
/// operation.
pub fn sf_round_pack(f: SfFmt, out: *SfW, neg: bool, m: *SfW, nm0: i32, e: i32) {
    var nm = nm0
    var t  = sfw_bitlen(m, nm)
    if t == 0 {
        sf_set_zero(f, out, neg)
        return
    }

    var top  = e + t - 1 // the exponent of m's leading bit
    var keep = f.prec
    if top < f.emin {
        keep = f.prec - (f.emin - top)
    }

    if keep <= 0 {
        // Below the smallest subnormal, 2^(emin - mbits). Exactly half of
        // it (keep == 0, m a power of two) ties to even, which is zero.
        sf_set_zero(f, out, neg)
        if keep == 0 && sfw_any_below(m, t - 1) {
            out->w[0] = out->w[0] | 1
        }

        return
    }

    var d           = t - keep
    var biased: i32 = 0
    if top >= f.emin {
        biased = top + f.bias - 1
    }

    if d > 0 {
        var rb = sfw_bit(m, d - 1)
        var st = sfw_any_below(m, d - 1)
        sfw_shr(m, nm, d)
        if rb != 0 && (st || (m->w[0] & 1) != 0) {
            sfw_add_word(m, nm, 1, 0)
        }
    } else if d < 0 {
        // Widening (a narrower format's significand, an integer): m may
        // need more limbs than the caller's operand had.
        var need = (keep + 33) / 32
        if need > nm {
            for var i: i32 = nm; i < need; ++i {
                m->w[i] = 0
            }

            nm = need
        }

        sfw_shl(m, nm, -d)
    }

    // m now has keep bits (keep + 1 after a carry). Encoding biased << mbits
    // plus m lets the hidden bit and any carry walk into the exponent field,
    // subnormal to normal included.
    var field = biased + (sfw_bitlen(m, nm) - 1 - f.mbits) + 1
    if sfw_bitlen(m, nm) <= f.mbits {
        field = 0
    }

    if field >= f.emask {
        sf_set_inf(f, out, neg)
        return
    }

    sfw_zero(out, f.nw)
    var cw = if nm < f.nw => nm else => f.nw
    sfw_copy(out, m, cw)
    add_at_(out, f.nw, biased as u32, f.mbits)
    if neg {
        out->w[f.nbits - 1 >> 5] = out->w[f.nbits - 1 >> 5] | (1 as u32) << ((f.nbits - 1 & 31) as u32)
    }
}

// === arithmetic =============================================================

fn limbs_(bits: i32) -> i32 {
    return (bits + 31) / 32 + 1
}

/// out = a + b, or a - b when `sub`.
pub fn sf_add(f: SfFmt, out: *SfW, a: *const SfW, b: *const SfW, sub: bool) {
    var x: SfU
    var y: SfU
    sf_unpack(f, a, &x)
    sf_unpack(f, b, &y)
    if sub {
        y.neg = !y.neg
    }

    if x.cls == SF_NAN || y.cls == SF_NAN {
        sf_set_nan(f, out)
        return
    }

    if x.cls == SF_INF {
        if y.cls == SF_INF && x.neg != y.neg {
            sf_set_nan(f, out)
            return
        }

        sf_set_inf(f, out, x.neg)
        return
    }

    if y.cls == SF_INF {
        sf_set_inf(f, out, y.neg)
        return
    }

    if x.cls == SF_ZERO && y.cls == SF_ZERO {
        sf_set_zero(f, out, x.neg && y.neg)
        return
    }

    var n = limbs_(f.prec + 4)
    if x.cls == SF_ZERO {
        sf_round_pack(f, out, y.neg, &y.m, n, y.e)
        return
    }

    if y.cls == SF_ZERO {
        sf_round_pack(f, out, x.neg, &x.m, n, x.e)
        return
    }

    // Three extra bits: guard, round and the jam.
    sfw_shl(&x.m, n, 3)
    sfw_shl(&y.m, n, 3)
    if x.e < y.e {
        sf_add_swap_(&x, &y)
    }

    sfw_shr_jam(&y.m, n, x.e - y.e)
    var neg = x.neg
    if x.neg == y.neg {
        sfw_add(&x.m, &y.m, n)
    } else {
        var c = sfw_cmp(&x.m, &y.m, n)
        if c == 0 {
            sf_set_zero(f, out, false)
            return
        }

        if c > 0 {
            sfw_sub(&x.m, &y.m, n)
        } else {
            sfw_sub(&y.m, &x.m, n)
            sfw_copy(&x.m, &y.m, n)
            neg = y.neg
        }
    }

    sf_round_pack(f, out, neg, &x.m, n, x.e - 3)
}

fn sf_add_swap_(x: *SfU, y: *SfU) {
    var t: SfU = *x
    *x = *y
    *y = t
}

/// out = a * b.
pub fn sf_mul(f: SfFmt, out: *SfW, a: *const SfW, b: *const SfW) {
    var x: SfU
    var y: SfU
    sf_unpack(f, a, &x)
    sf_unpack(f, b, &y)
    var neg = x.neg != y.neg
    if x.cls == SF_NAN || y.cls == SF_NAN {
        sf_set_nan(f, out)
        return
    }

    if x.cls == SF_INF || y.cls == SF_INF {
        if x.cls == SF_ZERO || y.cls == SF_ZERO {
            sf_set_nan(f, out)
            return
        }

        sf_set_inf(f, out, neg)
        return
    }

    if x.cls == SF_ZERO || y.cls == SF_ZERO {
        sf_set_zero(f, out, neg)
        return
    }

    var n      = (f.prec + 31) / 32
    var p: SfW
    sfw_mul(&p, &x.m, n, &y.m, n)
    sf_round_pack(f, out, neg, &p, 2 * n, x.e + y.e)
}

/// Shifts a finite nonzero significand so its top bit is bit prec - 1.
fn normalize_(f: SfFmt, u: *SfU) {
    var n  = (f.prec + 31) / 32
    var sh = f.prec - sfw_bitlen(&u->m, n)
    if sh > 0 {
        sfw_shl(&u->m, n, sh)
        u->e -= sh
    }
}

/// out = a / b.
pub fn sf_div(f: SfFmt, out: *SfW, a: *const SfW, b: *const SfW) {
    var x: SfU
    var y: SfU
    sf_unpack(f, a, &x)
    sf_unpack(f, b, &y)
    var neg = x.neg != y.neg
    if x.cls == SF_NAN || y.cls == SF_NAN {
        sf_set_nan(f, out)
        return
    }

    if x.cls == SF_INF {
        if y.cls == SF_INF {
            sf_set_nan(f, out)
            return
        }

        sf_set_inf(f, out, neg)
        return
    }

    if y.cls == SF_INF {
        sf_set_zero(f, out, neg)
        return
    }

    if y.cls == SF_ZERO {
        if x.cls == SF_ZERO {
            sf_set_nan(f, out)
            return
        }

        sf_set_inf(f, out, neg)
        return
    }

    if x.cls == SF_ZERO {
        sf_set_zero(f, out, neg)
        return
    }

    normalize_(f, &x)
    normalize_(f, &y)
    // q = (x.m << (prec + 2)) / y.m has prec + 2 or prec + 3 bits; the
    // remainder becomes the jam below it.
    var nu = limbs_(2 * f.prec + 2)
    var nv = (f.prec + 31) / 32
    sfw_shl(&x.m, nu, f.prec + 2)
    var q: SfW
    var r: SfW
    sfw_divmod(&q, &r, &x.m, nu, &y.m, nv)
    sfw_shl(&q, nu, 1)
    if !sfw_is_zero(&r, nv) {
        q.w[0] = q.w[0] | 1
    }

    sf_round_pack(f, out, neg, &q, nu, x.e - y.e - (f.prec + 2) - 1)
}

/// out = sqrt(a). sqrt(-0) is -0; any other negative is NaN.
pub fn sf_sqrt(f: SfFmt, out: *SfW, a: *const SfW) {
    var x: SfU
    sf_unpack(f, a, &x)
    if x.cls == SF_NAN {
        sf_set_nan(f, out)
        return
    }

    if x.cls == SF_ZERO {
        sf_set_zero(f, out, x.neg)
        return
    }

    if x.neg {
        sf_set_nan(f, out)
        return
    }

    if x.cls == SF_INF {
        sf_set_inf(f, out, false)
        return
    }

    normalize_(f, &x)
    // m << s with e - s even and 2 * prec + 4 or 5 bits: the root has
    // prec + 2 bits, and its inexactness is the jam.
    var s = f.prec + 4
    if (x.e - s & 1) != 0 {
        s += 1
    }

    var n = limbs_(2 * f.prec + 6)
    sfw_shl(&x.m, n, s)
    var r:      SfW
    var inexact     = sfw_isqrt(&r, &x.m, n)
    sfw_shl(&r, n, 1)
    if inexact {
        r.w[0] = r.w[0] | 1
    }

    sf_round_pack(f, out, false, &r, n, (x.e - s >> 1) - 1)
}

/// out = a * b + c, rounded once.
pub fn sf_fma(f: SfFmt, out: *SfW, a: *const SfW, b: *const SfW, c: *const SfW) {
    var x: SfU
    var y: SfU
    var z: SfU
    sf_unpack(f, a, &x)
    sf_unpack(f, b, &y)
    sf_unpack(f, c, &z)
    if x.cls == SF_NAN || y.cls == SF_NAN || z.cls == SF_NAN {
        sf_set_nan(f, out)
        return
    }

    var pneg = x.neg != y.neg
    if x.cls == SF_INF || y.cls == SF_INF {
        if x.cls == SF_ZERO || y.cls == SF_ZERO {
            sf_set_nan(f, out)
            return
        }

        if z.cls == SF_INF && z.neg != pneg {
            sf_set_nan(f, out)
            return
        }

        sf_set_inf(f, out, pneg)
        return
    }

    if z.cls == SF_INF {
        sf_set_inf(f, out, z.neg)
        return
    }

    var pzero = x.cls == SF_ZERO || y.cls == SF_ZERO
    if pzero {
        if z.cls == SF_ZERO {
            sf_set_zero(f, out, pneg && z.neg)
            return
        }

        sfw_copy(out, c, f.nw)
        return
    }

    var n       = (f.prec + 31) / 32
    var win     = 3 * f.prec + 8
    var nw      = limbs_(win)
    var p:  SfW
    sfw_zero(&p, SFW_LIMBS)
    sfw_mul(&p, &x.m, n, &y.m, n)
    var pe = x.e + y.e
    if z.cls == SF_ZERO {
        sf_round_pack(f, out, pneg, &p, 2 * n, pe)
        return
    }

    // Both into one window of `win` bits whose top is the higher top of the
    // two; what falls below the window is jammed.
    var ptop     = pe + sfw_bitlen(&p, 2 * n)
    var ztop     = z.e + sfw_bitlen(&z.m, n)
    var hi       = if ptop > ztop => ptop else => ztop
    var base     = hi - win
    var pm:  SfW
    var zm:  SfW
    sfw_zero(&pm, nw)
    sfw_zero(&zm, nw)
    sfw_copy(&pm, &p, 2 * n)
    sfw_copy(&zm, &z.m, n)
    fma_place_(&pm, nw, pe - base)
    fma_place_(&zm, nw, z.e - base)
    var neg = pneg
    if pneg == z.neg {
        sfw_add(&pm, &zm, nw)
    } else {
        var cc = sfw_cmp(&pm, &zm, nw)
        if cc == 0 {
            sf_set_zero(f, out, false)
            return
        }

        if cc > 0 {
            sfw_sub(&pm, &zm, nw)
        } else {
            sfw_sub(&zm, &pm, nw)
            sfw_copy(&pm, &zm, nw)
            neg = z.neg
        }
    }

    sf_round_pack(f, out, neg, &pm, nw, base)
}

fn fma_place_(m: *SfW, n: i32, sh: i32) {
    if sh >= 0 {
        sfw_shl(m, n, sh)
    } else {
        sfw_shr_jam(m, n, -sh)
    }
}

/// -1, 0, 1 for a <, ==, > b; 2 when unordered (a NaN).
pub fn sf_cmp(f: SfFmt, a: *const SfW, b: *const SfW) -> i32 {
    var ca = sf_class(f, a)
    var cb = sf_class(f, b)
    if ca == SF_NAN || cb == SF_NAN {
        return 2
    }

    if ca == SF_ZERO && cb == SF_ZERO {
        return 0
    }

    var na = sf_sign(f, a)
    var nb = sf_sign(f, b)
    if na != nb {
        return if na => -1 else => 1
    }

    // Same sign: the magnitude bits order like integers.
    var x: SfW
    var y: SfW
    sfw_copy(&x, a, f.nw)
    sfw_copy(&y, b, f.nw)
    var top       = f.nbits - 1 >> 5
    var mask: u32 = ~((1 as u32) << ((f.nbits - 1 & 31) as u32))
    x.w[top] = x.w[top] & mask
    y.w[top] = y.w[top] & mask
    var c = sfw_cmp(&x, &y, f.nw)
    return if na => -c else => c
}

/// out = -a: the sign bit flipped, NaN included.
pub fn sf_neg(f: SfFmt, out: *SfW, a: *const SfW) {
    sfw_copy(out, a, f.nw)
    var top = f.nbits - 1 >> 5
    out->w[top] = out->w[top] ^ (1 as u32) << ((f.nbits - 1 & 31) as u32)
}

/// out = |a|: the sign bit cleared.
pub fn sf_abs(f: SfFmt, out: *SfW, a: *const SfW) {
    sfw_copy(out, a, f.nw)
    var top = f.nbits - 1 >> 5
    out->w[top] = out->w[top] & ~((1 as u32) << ((f.nbits - 1 & 31) as u32))
}

// === conversions ============================================================

/// out (format t) = a (format s), rounded once: no double rounding however
/// far the two are apart.
pub fn sf_convert(t: SfFmt, out: *SfW, s: SfFmt, a: *const SfW) {
    var x: SfU
    sf_unpack(s, a, &x)
    if x.cls == SF_NAN {
        sf_set_nan(t, out)
        return
    }

    if x.cls == SF_INF {
        sf_set_inf(t, out, x.neg)
        return
    }

    if x.cls == SF_ZERO {
        sf_set_zero(t, out, x.neg)
        return
    }

    sf_round_pack(t, out, x.neg, &x.m, limbs_(s.prec), x.e)
}

/// out = the integer (magnitude m over nm limbs, sign neg), rounded.
pub fn sf_from_int(f: SfFmt, out: *SfW, m: *const SfW, nm: i32, neg: bool) {
    var t: SfW
    sfw_zero(&t, SFW_LIMBS)
    sfw_copy(&t, m, nm)
    if sfw_is_zero(&t, nm) {
        sf_set_zero(f, out, false)
        return
    }

    sf_round_pack(f, out, neg, &t, nm, 0)
}

/// The integer part of a (toward zero) as a magnitude over nm limbs and a
/// sign; returns false when |a| does not fit nm * 32 bits, or a is NaN or
/// infinite. The caller saturates.
pub fn sf_to_int(f: SfFmt, a: *const SfW, m: *SfW, nm: i32, neg: *bool) -> bool {
    var x: SfU
    sf_unpack(f, a, &x)
    *neg = x.neg
    sfw_zero(m, nm)
    if x.cls == SF_NAN || x.cls == SF_INF {
        return false
    }

    if x.cls == SF_ZERO {
        return true
    }

    var bl = sfw_bitlen(&x.m, limbs_(f.prec))
    if x.e >= 0 {
        if bl + x.e > nm * 32 {
            return false
        }

        sfw_copy(m, &x.m, if limbs_(f.prec) < nm => limbs_(f.prec) else => nm)
        sfw_shl(m, nm, x.e)
        return true
    }

    if -x.e >= bl {
        return true
    }

    sfw_shr(&x.m, limbs_(f.prec), -x.e)
    sfw_copy(m, &x.m, if limbs_(f.prec) < nm => limbs_(f.prec) else => nm)
    return true
}

// === value-level entry points ===============================================
//
// What num/f256.k and num/f512.k call: encodings travel as u512 (an f256
// in its low 256 bits), so the classes never see a limb.

/// w = the low f.nw limbs of v.
pub fn sf_load(f: SfFmt, w: *SfW, v: u512) {
    sfw_zero(w, SFW_LIMBS)
    var x = v
    for var i: i32 = 0; i < f.nw; ++i {
        w->w[i] = x as u32
        x       = x >> 32
    }
}

/// The f.nw limbs of w as an integer.
pub fn sf_store(f: SfFmt, w: *const SfW) -> u512 {
    var v: u512 = 0
    var i       = f.nw - 1
    while i >= 0 {
        v = v << 32 | (w->w[i] as u512)
        i -= 1
    }

    return v
}

/// sf_op: a + b.
pub eval SF_OP_ADD: i32 = 0
/// sf_op: a - b.
pub eval SF_OP_SUB: i32 = 1
/// sf_op: a * b.
pub eval SF_OP_MUL: i32 = 2
/// sf_op: a / b.
pub eval SF_OP_DIV: i32 = 3
/// sf_op: sqrt(a).
pub eval SF_OP_SQRT: i32 = 4
/// sf_op: a * b + c, rounded once.
pub eval SF_OP_FMA: i32 = 5
/// sf_op: -a.
pub eval SF_OP_NEG: i32 = 6
/// sf_op: |a|.
pub eval SF_OP_ABS: i32 = 7

/// The encoding of operation `which` (SF_OP_*) on encodings a, b, c (b, c unused by the unary ones).
pub fn sf_op(f: SfFmt, which: i32, a: u512, b: u512, c: u512) -> u512 {
    var x: SfW
    var y: SfW
    var z: SfW
    var r: SfW
    sf_load(f, &x, a)
    sf_load(f, &y, b)
    if which == SF_OP_ADD {
        sf_add(f, &r, &x, &y, false)
    } else if which == SF_OP_SUB {
        sf_add(f, &r, &x, &y, true)
    } else if which == SF_OP_MUL {
        sf_mul(f, &r, &x, &y)
    } else if which == SF_OP_DIV {
        sf_div(f, &r, &x, &y)
    } else if which == SF_OP_SQRT {
        sf_sqrt(f, &r, &x)
    } else if which == SF_OP_FMA {
        sf_load(f, &z, c)
        sf_fma(f, &r, &x, &y, &z)
    } else if which == SF_OP_NEG {
        sf_neg(f, &r, &x)
    } else {
        sf_abs(f, &r, &x)
    }

    return sf_store(f, &r)
}

/// -1, 0, 1, or 2 (unordered) comparing two encodings.
pub fn sf_cmp_bits(f: SfFmt, a: u512, b: u512) -> i32 {
    var x: SfW
    var y: SfW
    sf_load(f, &x, a)
    sf_load(f, &y, b)
    return sf_cmp(f, &x, &y)
}

/// SF_ZERO, SF_FINITE, SF_INF or SF_NAN of an encoding.
pub fn sf_class_bits(f: SfFmt, a: u512) -> i32 {
    var x: SfW
    sf_load(f, &x, a)
    return sf_class(f, &x)
}

/// Whether an encoding is subnormal.
pub fn sf_subnormal_bits(f: SfFmt, a: u512) -> bool {
    var x: SfW
    sf_load(f, &x, a)
    return sf_is_subnormal(f, &x)
}

/// An encoding of format s re-encoded in format t, rounded once.
pub fn sf_cvt(t: SfFmt, s: SfFmt, a: u512) -> u512 {
    var x: SfW
    var r: SfW
    sf_load(s, &x, a)
    sf_convert(t, &r, s, &x)
    return sf_store(t, &r)
}

/// The encoding of the integer `neg ? -mag : mag`, rounded.
pub fn sf_from_mag(f: SfFmt, mag: u512, neg: bool) -> u512 {
    var m:  SfW
    var r:  SfW
    var all     = sf_fmt(512, 15)
    sf_load(all, &m, mag)
    sf_from_int(f, &r, &m, 16, neg)
    return sf_store(f, &r)
}

/// The encoding truncated toward zero to a `width`-bit integer, signed or
/// not, saturating at the type's limits (casting.mdx); NaN is 0. The
/// result is the integer's two's-complement bits in the low `width` bits.
pub fn sf_to_sat(f: SfFmt, a: u512, width: i32, is_signed: bool) -> u512 {
    var x: SfW
    var m: SfW
    sf_load(f, &x, a)
    if sf_class(f, &x) == SF_NAN {
        return 0
    }

    var neg       = false
    var ok        = sf_to_int(f, &x, &m, 16, &neg)
    var all       = sf_fmt(512, 15)
    var mag       = sf_store(all, &m)
    var one: u512 = 1
    if is_signed {
        var lim = one << ((width - 1) as u32) // 2^(width-1)
        if neg {
            if !ok || mag > lim { // MIN
                return lim
            }

            return 0 - mag
        }

        if !ok || mag >= lim { // MAX
            return lim - 1
        }

        return mag
    }

    if neg {
        return 0
    }

    var maxu: u512 = if width >= 512 => 0 - one else => (one << (width as u32)) - 1
    if !ok || mag > maxu {
        return maxu
    }

    return mag
}

/// x87 extended (sign/exponent word, 64-bit significand with its explicit
/// integer bit) as the 79-bit implicit-bit encoding sf_fmt(79, 15) names,
/// which is how the engine handles f80. A pseudo-denormal (exponent 0,
/// integer bit set) is the normal it equals; an unnormal (integer bit clear
/// under a nonzero exponent) is invalid on every x87 since the 387 and
/// reads as NaN.
pub fn sf_from_x87(se: u16, m: u64) -> u512 {
    var e    = (se & 0x7FFF) as u64
    var s    = (se >> 15 & 1) as u512
    var frac = m & 0x7FFFFFFFFFFFFFFF
    var top  = m >> 63 & 1
    if e == 0x7FFF {
        if frac == 0 {
            return s << 78 | (0x7FFF as u512) << 63
        }

        return (0x7FFF as u512) << 63 | (1 as u512) << 62
    }

    if e != 0 && top == 0 {
        return (0x7FFF as u512) << 63 | (1 as u512) << 62
    }

    if e == 0 && top != 0 {
        e = 1
    }

    return s << 78 | (e as u512) << 63 | (frac as u512)
}

/// The 79-bit encoding back as x87: (sign/exponent word, significand).
pub fn sf_to_x87(v: u512, se: *u16, m: *u64) {
    var e    = (v >> 63 & 0x7FFF) as u64
    var frac = (v & 0x7FFFFFFFFFFFFFFF) as u64
    *se = (v >> 78 & 1) as u16 << 15 | (e as u16)
    var top: u64 = if e == 0 => 0 else => 1
    if e == 0x7FFF && frac != 0 {
        frac = frac | 0x4000000000000000
    }

    *m = top << 63 | frac
}
