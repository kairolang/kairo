/// --- The Kairo Project ------------- Lib/builtin/num/softfloat_text.k --- ///
///
///   \brief Decimal text for the software floats: correctly rounded
///          parsing (decimal and hex), and the shortest round-trip and
///          fixed-precision digits the f-string formatter lays out.
///
///   \detail
///     Both directions reduce to one question: where does x * 10^t fall
///     against a set of integer breakpoints, for an exact binary x and an
///     integer t that can reach a million at binary512 (its range is
///     10^+-1262612). Computing 10^t exactly at that size is out of the
///     question, so 5^|t| (10^t = 5^t * 2^t) is carried as an interval
///     [lo, hi] * 2^x of `wp` bits, rounded down and up respectively at
///     every step of the binary powering. Every decision is made on both
///     ends of the interval; when they agree the answer is the exact one,
///     when they do not `wp` grows and the step repeats (Ziv's strategy).
///     For |t| <= POW5_EXACT (POW5_EXACT_DIV for a parse's division) the
///     power is exact and no decision can be uncertain; that range holds
///     every case that is exactly ON a breakpoint (a decimal exactly halfway between two floats, a float
///     whose shortest digits tie), since those need 5^|t| to divide a
///     number of at most a few thousand bits.
///
///     The breakpoints are integers in a scale where x * 10^t is
///     multiplied by 4, and a value is carried as a "proxy": its floor with
///     the lowest bit set when anything was below it (a jam, as in
///     softfloat.k). A proxy compares with every even integer exactly as
///     the real number does, and every breakpoint here is even.
///
///   \par Limits
///     A decimal string's first 1000 significant digits are used exactly;
///     a nonzero digit beyond them is folded into a trailing 1 (the value
///     is then strictly between the truncation and the next decimal at
///     that position, which is exact unless a binary breakpoint sits in
///     that gap -- only possible for strings of more than 1000 digits).
///     Fixed-precision output gives at most 600 significant digits.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import num::softfloat::*

/// Limbs in a decimal work buffer: 256 x 32 = 8192 bits. The largest
/// products are 1001 decimal digits (3326 bits) times 5^1000 (2322 bits),
/// and the same digits times a 5^n interval at a parse's widest precision
/// (3326 + 489 + 192 bits, dec_to_bin_).
pub eval SFB_LIMBS: i32 = 256

/// The largest |t| for which 5^|t| is computed exactly (2322 bits).
eval POW5_EXACT: i32 = 1000

/// The same for a parse's negative exponent (3367 bits). A decimal exactly
/// halfway between two floats is d * 10^-n with 5^n dividing d, so with
/// at most MAX_DIGITS digits n stays below 1000 / log10(5) = 1431. (A
/// positive exponent never needs more than about 211: 5^q would have to
/// divide a significand of prec + 1 bits.)
eval POW5_EXACT_DIV: i32 = 1450

/// Significant decimal digits a parse uses exactly.
eval MAX_DIGITS: i32 = 1000

/// Significant digits fixed-precision output produces at most.
pub eval SF_MAX_PREC: i32 = 600

/// A wide work integer for the decimal conversions (see SfW).
pub struct SfB {
    /// The limbs, least significant first.
    pub var w: [u32; 256]
}

// --- SfB primitives ---------------------------------------------------------
//
// The same routines as softfloat.k's sfw_*, at this width: a mechanical copy
// (SfW -> SfB), kept separate so the arithmetic's buffers stay small.
// Scripts/gen_softfloat.py writes the block; edit softfloat.k instead.

// BEGIN-GENERATED(sfb)
/// Zeroes limbs [0, n).
pub fn sfb_zero(a: *SfB, n: i32) {
    for var i: i32 = 0; i < n; ++i {
        a->w[i] = 0
    }
}

/// Copies n limbs from s to d.
pub fn sfb_copy(d: *SfB, s: *const SfB, n: i32) {
    for var i: i32 = 0; i < n; ++i {
        d->w[i] = s->w[i]
    }
}

/// Whether limbs [0, n) are all zero.
pub fn sfb_is_zero(a: *const SfB, n: i32) -> bool {
    for var i: i32 = 0; i < n; ++i {
        if a->w[i] != 0 {
            return false
        }
    }

    return true
}

/// Leading zero bits of x; 32 for 0.
/// Index of the highest set bit plus one; 0 for zero.
pub fn sfb_bitlen(a: *const SfB, n: i32) -> i32 {
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
pub fn sfb_bit(a: *const SfB, i: i32) -> u32 {
    return a->w[i >> 5] >> ((i & 31) as u32) & 1
}

/// Whether any of bits [0, k) is set.
pub fn sfb_any_below(a: *const SfB, k: i32) -> bool {
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
pub fn sfb_shl(a: *SfB, n: i32, k: i32) {
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
pub fn sfb_shr(a: *SfB, n: i32, k: i32) -> bool {
    if k <= 0 {
        return false
    }

    var lost = sfb_any_below(a, if k < n * 32 => k else => n * 32)
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
pub fn sfb_shr_jam(a: *SfB, n: i32, k: i32) {
    if sfb_shr(a, n, k) {
        a->w[0] = a->w[0] | 1
    }
}

/// a += b over n limbs; returns the carry out.
pub fn sfb_add(a: *SfB, b: *const SfB, n: i32) -> u32 {
    var c: u64 = 0
    for var i: i32 = 0; i < n; ++i {
        var s = (a->w[i] as u64) + (b->w[i] as u64) + c
        a->w[i] = s as u32
        c       = s >> 32
    }

    return c as u32
}

/// a -= b over n limbs; returns the borrow out.
pub fn sfb_sub(a: *SfB, b: *const SfB, n: i32) -> u32 {
    var br: u64 = 0
    for var i: i32 = 0; i < n; ++i {
        var s = (a->w[i] as u64) - (b->w[i] as u64) - br
        a->w[i] = s as u32
        br      = s >> 32 & 1
    }

    return br as u32
}

/// -1, 0 or 1 as a <, ==, > b over n limbs.
pub fn sfb_cmp(a: *const SfB, b: *const SfB, n: i32) -> i32 {
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
pub fn sfb_add_word(a: *SfB, n: i32, x: u32, at: i32) {
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
pub fn sfb_mul_small(a: *SfB, n: i32, x: u32, y: u32) -> u32 {
    var c = y as u64
    for var i: i32 = 0; i < n; ++i {
        var p = (a->w[i] as u64) * (x as u64) + c
        a->w[i] = p as u32
        c       = p >> 32
    }

    return c as u32
}

/// r = a * b; r gets na + nb limbs and must not alias a or b.
pub fn sfb_mul(r: *SfB, a: *const SfB, na: i32, b: *const SfB, nb: i32) {
    sfb_zero(r, na + nb)
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
pub fn sfb_used(a: *const SfB, n: i32) -> i32 {
    var k = n
    while k > 1 && a->w[k - 1] == 0 {
        k -= 1
    }

    return k
}

/// q = u / v, r = u % v (Knuth, TAOCP 4.3.1 Algorithm D, base 2^32).
/// u has nu limbs, v has nv; q gets nu limbs, r gets nv. v must be nonzero.
/// u and v are not modified.
pub fn sfb_divmod(q: *SfB, r: *SfB, u: *const SfB, nu: i32, v: *const SfB, nv: i32) {
    var n = sfb_used(v, nv)
    var m = sfb_used(u, nu)
    sfb_zero(q, nu)
    sfb_zero(r, nv)
    if m < n {
        sfb_copy(r, u, m)
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
    var vn: SfB
    var un: SfB
    sfb_zero(&vn, n)
    sfb_zero(&un, m + 1)
    sfb_copy(&vn, v, n)
    sfb_copy(&un, u, m)
    sfb_shl(&vn, n, s)
    sfb_shl(&un, m + 1, s)
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
    sfb_copy(r, &un, n)
    sfb_shr(r, n, s)
}

// END-GENERATED(sfb)


/// a /= d (one limb); returns the remainder.
fn sfb_div_small(a: *SfB, n: i32, d: u32) -> u32 {
    var rem: u64 = 0
    var i        = n - 1
    while i >= 0 {
        var cur = rem << 32 | (a->w[i] as u64)
        a->w[i] = (cur / (d as u64)) as u32
        rem     = cur % (d as u64)
        i -= 1
    }

    return rem as u32
}

fn sfb_set_u32(a: *SfB, v: u32) {
    sfb_zero(a, SFB_LIMBS)
    a->w[0] = v
}

/// a = 10^n (n <= 1900).
fn sfb_pow10(a: *SfB, n: i32) {
    sfb_set_u32(a, 1)
    var k = n
    while k >= 9 {
        sfb_mul_small(a, SFB_LIMBS, 1000000000, 0)
        k -= 9
    }

    while k > 0 {
        sfb_mul_small(a, SFB_LIMBS, 10, 0)
        k -= 1
    }
}

fn nl_(a: *const SfB) -> i32 {
    return sfb_used(a, SFB_LIMBS)
}

/// r = a * b (r distinct), sized to the operands' used limbs.
fn sfb_mulx(r: *SfB, a: *const SfB, b: *const SfB) {
    var na = nl_(a)
    var nb = nl_(b)
    sfb_mul(r, a, na, b, nb)
    for var i: i32 = na + nb; i < SFB_LIMBS; ++i {
        r->w[i] = 0
    }
}

/// q = a / b, r = a % b over the full width.
fn sfb_divx(q: *SfB, r: *SfB, a: *const SfB, b: *const SfB) {
    var na = nl_(a)
    sfb_divmod(q, r, a, na, b, nl_(b))
    for var i: i32 = na; i < SFB_LIMBS; ++i {
        q->w[i] = 0
    }

    for var i: i32 = nl_(b); i < SFB_LIMBS; ++i {
        r->w[i] = 0
    }
}

// === powers of five ==========================================================

/// a = 5^n exactly (n <= POW5_EXACT_DIV), by binary powering.
fn pow5_exact_(a: *SfB, n: i32) {
    var t: SfB
    sfb_set_u32(a, 1)
    if n == 0 {
        return
    }

    var b = 31 - sf_clz32(n as u32)
    while b >= 0 {
        sfb_mulx(&t, a, a)
        sfb_copy(a, &t, SFB_LIMBS)
        if (n >> (b as u32) & 1) != 0 {
            sfb_mul_small(a, SFB_LIMBS, 5, 0)
        }

        b -= 1
    }
}

/// Cuts a * 2^*x to `wp` bits, rounding down, or up when `up`.
fn trunc_(a: *SfB, x: *i32, wp: i32, up: bool) {
    var bl = sfb_bitlen(a, SFB_LIMBS)
    if bl <= wp {
        return
    }

    var lost = sfb_shr(a, SFB_LIMBS, bl - wp)
    *x = *x + (bl - wp)
    if up && lost {
        sfb_add_word(a, SFB_LIMBS, 1, 0)
    }
}

/// 5^n within [lo * 2^xlo, hi * 2^xhi], each `wp` bits; returns whether
/// the two are the exact power (then lo == hi, xlo == xhi == 0).
fn pow5_(n: i32, wp: i32, lo: *SfB, xlo: *i32, hi: *SfB, xhi: *i32, exact_max: i32) -> bool {
    *xlo = 0
    *xhi = 0
    if n <= exact_max {
        pow5_exact_(lo, n)
        sfb_copy(hi, lo, SFB_LIMBS)
        return true
    }

    var t: SfB
    sfb_set_u32(lo, 1)
    sfb_set_u32(hi, 1)
    var b = 31 - sf_clz32(n as u32)
    while b >= 0 {
        sfb_mulx(&t, lo, lo)
        sfb_copy(lo, &t, SFB_LIMBS)
        *xlo = *xlo * 2
        trunc_(lo, xlo, wp, false)
        sfb_mulx(&t, hi, hi)
        sfb_copy(hi, &t, SFB_LIMBS)
        *xhi = *xhi * 2
        trunc_(hi, xhi, wp, true)
        if (n >> (b as u32) & 1) != 0 {
            sfb_mul_small(lo, SFB_LIMBS, 5, 0)
            sfb_mul_small(hi, SFB_LIMBS, 5, 0)
            trunc_(lo, xlo, wp, false)
            trunc_(hi, xhi, wp, true)
        }

        b -= 1
    }

    return false
}

// === decimal -> binary =======================================================

/// Rounds m * 2^e into f: m is cut to prec + 64 bits with a jam first (64
/// bits below any rounding position, subnormal ones included), then
/// sf_round_pack does the rest.
fn round_big_(f: SfFmt, out: *SfW, neg: bool, m: *SfB, e: i32) {
    var bl   = sfb_bitlen(m, SFB_LIMBS)
    var ee   = e
    var keep = f.prec + 64
    if bl > keep {
        sfb_shr_jam(m, SFB_LIMBS, bl - keep)
        ee += bl - keep
    }

    var w: SfW
    var nw     = (keep + 31) / 32 + 1
    for var i: i32 = 0; i < nw; ++i {
        w.w[i] = m->w[i]
    }

    sf_round_pack(f, out, neg, &w, nw, ee)
}

/// Same as round_big_ but leaves m alone.
fn round_copy_(f: SfFmt, out: *SfW, neg: bool, m: *const SfB, e: i32) {
    var t: SfB
    sfb_copy(&t, m, SFB_LIMBS)
    round_big_(f, out, neg, &t, e)
}

/// out = round(d * 10^q), d > 0 exact.
fn dec_to_bin_(f: SfFmt, out: *SfW, neg: bool, d: *const SfB, q: i32) {
    var lo:  SfB
    var hi:  SfB
    var t:   SfB
    var t2:  SfB
    var r:   SfB
    var r1:  SfW
    var r2:  SfW
    var xlo: i32 = 0
    var xhi: i32 = 0
    // Ziv's loop: P + 96 bits decides all but values within about 2^-P of
    // a breakpoint; the last round is as wide as d itself, which decides
    // a string that is a breakpoint's digits cut short (or one unit past),
    // the closest any decimal of d's length comes to one in practice.
    var wp   = f.prec + 96
    var last = sfb_bitlen(d, SFB_LIMBS) + f.prec + 192
    if last < 4 * wp {
        last = 4 * wp
    }

    var tries: i32 = 0
    while true {
        if q >= 0 {
            var exact = pow5_(q, wp, &lo, &xlo, &hi, &xhi, POW5_EXACT)
            sfb_mulx(&t, d, &lo)
            round_big_(f, &r1, neg, &t, q + xlo)
            if exact {
                sfw_copy(out, &r1, f.nw)
                return
            }

            sfb_mulx(&t, d, &hi)
            round_big_(f, &r2, neg, &t, q + xhi)
        } else {
            var n     = -q
            var exact = pow5_(n, wp, &lo, &xlo, &hi, &xhi, POW5_EXACT_DIV)
            // value = d / (5^n 2^n); quotients of prec + 4 or more bits.
            var s = f.prec + 4 + sfb_bitlen(&hi, SFB_LIMBS) - sfb_bitlen(d, SFB_LIMBS)
            if s < 0 {
                s = 0
            }

            sfb_copy(&t2, d, SFB_LIMBS)
            sfb_shl(&t2, SFB_LIMBS, s)
            // Lower end: divided by the upper power.
            sfb_divx(&t, &r, &t2, &hi)
            jam1_(&t, !sfb_is_zero(&r, SFB_LIMBS))
            round_big_(f, &r1, neg, &t, -n - s - xhi - 1)
            if exact {
                sfw_copy(out, &r1, f.nw)
                return
            }

            sfb_divx(&t, &r, &t2, &lo)
            jam1_(&t, !sfb_is_zero(&r, SFB_LIMBS))
            round_big_(f, &r2, neg, &t, -n - s - xlo - 1)
        }

        if sfw_cmp(&r1, &r2, f.nw) == 0 || wp >= last {
            sfw_copy(out, &r1, f.nw)
            return
        }

        tries += 1
        wp = if tries == 1 => wp * 2 else => last
    }
}

/// Shifts a quotient left one and sets the new low bit when the
/// remainder was nonzero: the jam below it.
fn jam1_(a: *SfB, inexact: bool) {
    sfb_shl(a, SFB_LIMBS, 1)
    if inexact {
        a->w[0] = a->w[0] | 1
    }
}

fn lower_(c: u8) -> u8 {
    if c >= 65 && c <= 90 {
        return c + 32
    }

    return c
}

fn word_at_(p: *const u8, n: usize, at: usize, w: *const u8, wn: usize) -> bool {
    if at + wn != n {
        return false
    }

    for var i: usize = 0; i < wn; ++i {
        if lower_(p[at + i]) != w[i] {
            return false
        }
    }

    return true
}

fn hexdig_(c: u8) -> i32 {
    if c >= 48 && c <= 57 {
        return c - 48
    }

    var l = lower_(c)
    if l >= 97 && l <= 102 {
        return l - 87
    }

    return -1
}

/// Parses p[0..n) as a float of format f into out: an optional sign, then
/// decimal digits with an optional point and `e` exponent, or `0x` hex
/// digits with an optional point and `p` exponent, or `inf`, `infinity`,
/// `nan` (any case). `_` between digits is skipped. Correctly rounded.
/// Returns false (out untouched) when the text is not a float.
pub fn sf_parse(f: SfFmt, out: *SfW, p: *const u8, n: usize) -> bool {
    var i:  usize = 0
    var neg       = false
    if i < n && (p[i] == 43 || p[i] == 45) {
        neg = p[i] == 45
        i += 1
    }

    if i >= n {
        return false
    }

    var infw: [u8; 8] = [105, 110, 102, 105, 110, 105, 116, 121] // "infinity"
    var nanw: [u8; 3] = [110, 97, 110]
    if word_at_(p, n, i, &infw[0], 3) || word_at_(p, n, i, &infw[0], 8) {
        sf_set_inf(f, out, neg)
        return true
    }

    if word_at_(p, n, i, &nanw[0], 3) {
        sf_set_nan(f, out)
        return true
    }

    var d: SfB
    sfb_zero(&d, SFB_LIMBS)
    var nd:     i32 = 0     // significant digits taken
    var any         = false // a digit was seen
    var dropped     = false // a nonzero digit beyond MAX_DIGITS
    var scale:  i32 = 0     // the exponent the digits imply
    if i + 1 < n && p[i] == 48 && lower_(p[i + 1]) == 120 {
        // Hex: the digits are the binary significand.
        i += 2
        var point = false
        while i < n {
            var c = p[i]
            if c == 95 {
                i += 1
                continue
            }

            if c == 46 {
                if point {
                    return false
                }

                point = true
                i += 1
                continue
            }

            var h = hexdig_(c)
            if h < 0 {
                break
            }

            any = true
            if nd > 0 || h != 0 {
                if nd < MAX_DIGITS {
                    sfb_mul_small(&d, SFB_LIMBS, 16, h as u32)
                    nd += 1
                    if point {
                        scale -= 4
                    }
                } else {
                    if h != 0 {
                        dropped = true
                    }

                    if !point {
                        scale += 4
                    }
                }
            } else if point {
                scale -= 4
            }

            i += 1
        }

        if !any {
            return false
        }

        var ex: i32 = 0
        if i < n {
            if lower_(p[i]) != 112 {
                return false
            }

            i += 1
            if !exp_(p, n, &i, &ex) {
                return false
            }
        }

        if i != n {
            return false
        }

        if sfb_is_zero(&d, SFB_LIMBS) {
            sf_set_zero(f, out, neg)
            return true
        }

        if dropped {
            sfb_shl(&d, SFB_LIMBS, 1)
            d.w[0] = d.w[0] | 1
            scale -= 1
        }

        round_big_(f, out, neg, &d, clamp_add_(scale, ex))
        return true
    }

    var point = false
    while i < n {
        var c = p[i]
        if c == 95 {
            i += 1
            continue
        }

        if c == 46 {
            if point {
                return false
            }

            point = true
            i += 1
            continue
        }

        if c < 48 || c > 57 {
            break
        }

        any = true
        var v = (c - 48) as u32
        if nd > 0 || v != 0 {
            if nd < MAX_DIGITS {
                sfb_mul_small(&d, SFB_LIMBS, 10, v)
                nd += 1
                if point {
                    scale -= 1
                }
            } else {
                if v != 0 {
                    dropped = true
                }

                if !point {
                    scale += 1
                }
            }
        } else if point {
            scale -= 1
        }

        i += 1
    }

    if !any {
        return false
    }

    var ex: i32 = 0
    if i < n {
        if lower_(p[i]) != 101 {
            return false
        }

        i += 1
        if !exp_(p, n, &i, &ex) {
            return false
        }
    }

    if i != n {
        return false
    }

    if sfb_is_zero(&d, SFB_LIMBS) {
        sf_set_zero(f, out, neg)
        return true
    }

    if dropped {
        sfb_mul_small(&d, SFB_LIMBS, 10, 1)
        scale -= 1
        nd += 1
    }

    var q = clamp_add_(scale, ex)
    // value < 10^(nd + q) and >= 10^(nd + q - 1): settle what is plainly
    // out of range before powering. log10(2) < 0.30103.
    var top    = nd + q
    var maxdec = (((f.bias + 1) as i64) * 30103 / 100000) as i32 + 2
    var mindec = (((f.emin - f.mbits) as i64) * 30103 / 100000) as i32 - 2
    if top - 1 > maxdec {
        sf_set_inf(f, out, neg)
        return true
    }

    if top < mindec {
        sf_set_zero(f, out, neg)
        return true
    }

    dec_to_bin_(f, out, neg, &d, q)
    return true
}

/// a + b for exponents, held well inside i32 (anything past +-2^28 is far
/// outside every format's range in either base).
fn clamp_add_(a: i32, b: i32) -> i32 {
    var s = (a as i64) + (b as i64)
    if s > 268435456 {
        return 268435456
    }

    if s < -268435456 {
        return -268435456
    }

    return s as i32
}

/// A signed decimal exponent at p[*i..]; saturates at +-2^28.
fn exp_(p: *const u8, n: usize, i: *usize, out: *i32) -> bool {
    var k   = *i
    var neg = false
    if k < n && (p[k] == 43 || p[k] == 45) {
        neg = p[k] == 45
        k += 1
    }

    var any     = false
    var v:  i32 = 0
    while k < n {
        var c = p[k]
        if c == 95 {
            k += 1
            continue
        }

        if c < 48 || c > 57 {
            break
        }

        any = true
        if v < 268435456 {
            v = v * 10 + ((c - 48) as i32)
        }

        k += 1
    }

    if !any {
        return false
    }

    *i   = k
    *out = if neg => -v else => v
    return true
}

// === binary -> decimal =======================================================

/// The digits a formatter lays out: d[0..n) as ASCII, the value
/// 0.d1d2... * 10^(k + 1), i.e. d1.d2... * 10^k.
pub struct SfDigits {
    /// The ASCII digits.
    pub var d: [u8; 640]
    /// How many digits.
    pub var n: i32 = 0
    /// The decimal exponent of the first digit.
    pub var k: i32 = 0
}

/// Proxies of Z = mx * 2^ex * 10^t * 4 into plo, phi; returns whether the
/// two are equal (exact power). See the file header for "proxy".
fn scale_(mx: *const SfB, ex: i32, t: i32, wp: i32, plo: *SfB, phi: *SfB) -> bool {
    var lo:  SfB
    var hi:  SfB
    var a:   SfB
    var b:   SfB
    var r:   SfB
    var xlo: i32 = 0
    var xhi: i32 = 0
    var s        = ex + t + 2
    if t >= 0 {
        var exact = pow5_(t, wp, &lo, &xlo, &hi, &xhi, POW5_EXACT)
        sfb_mulx(&a, mx, &lo)
        shift_proxy_(&a, s + xlo, false, plo)
        if exact {
            sfb_copy(phi, plo, SFB_LIMBS)
            return true
        }

        sfb_mulx(&a, mx, &hi)
        shift_proxy_(&a, s + xhi, true, phi)
        return false
    }

    var exact2 = pow5_(-t, wp, &lo, &xlo, &hi, &xhi, POW5_EXACT)
    // Lower end: mx * 2^(s - xhi) / hi.
    div_proxy_(mx, s - xhi, &hi, false, plo)
    if exact2 {
        sfb_copy(phi, plo, SFB_LIMBS)
        return true
    }

    div_proxy_(mx, s - xlo, &lo, true, phi)
    return false
}

/// p = proxy of a * 2^s: exact (`upper` false) is floor | jam; the upper
/// end of an interval (`upper`) is the proxy of the value just below it:
/// (ceil - 1) | 1.
fn shift_proxy_(a: *SfB, s: i32, upper: bool, p: *SfB) {
    if s >= 0 {
        sfb_shl(a, SFB_LIMBS, s)
        sfb_copy(p, a, SFB_LIMBS)
        if upper {
            sfb_sub_one_(p)
            p->w[0] = p->w[0] | 1
        }

        return
    }

    var lost = sfb_shr(a, SFB_LIMBS, -s)
    sfb_copy(p, a, SFB_LIMBS)
    if upper {
        if !lost {
            sfb_sub_one_(p)
        }

        p->w[0] = p->w[0] | 1
    } else if lost {
        p->w[0] = p->w[0] | 1
    }
}

/// p = proxy of mx * 2^s / den (see shift_proxy_ for `upper`).
fn div_proxy_(mx: *const SfB, s: i32, den: *const SfB, upper: bool, p: *SfB) {
    var num: SfB
    var dd:  SfB
    var r:   SfB
    sfb_copy(&num, mx, SFB_LIMBS)
    sfb_copy(&dd, den, SFB_LIMBS)
    if s >= 0 {
        sfb_shl(&num, SFB_LIMBS, s)
    } else {
        sfb_shl(&dd, SFB_LIMBS, -s)
    }

    sfb_divx(p, &r, &num, &dd)
    var lost = !sfb_is_zero(&r, SFB_LIMBS)
    if upper {
        if !lost {
            sfb_sub_one_(p)
        }

        p->w[0] = p->w[0] | 1
    } else if lost {
        p->w[0] = p->w[0] | 1
    }
}

fn sfb_sub_one_(a: *SfB) {
    var one: SfB
    sfb_set_u32(&one, 1)
    sfb_sub(a, &one, SFB_LIMBS)
}

// The digit decisions, on one proxy p, with u4 = 4 * 10^j: the multiples
// of 10^j in the x * 10^t scale are the multiples of u4 in the proxy's.

/// Smallest d with d * u4 >= Z (incl) or > Z.
fn dlow_(p: *const SfB, u4: *const SfB, incl: bool, d: *SfB) {
    var r: SfB
    sfb_divx(d, &r, p, u4)
    if !(sfb_is_zero(&r, SFB_LIMBS) && incl) {
        sfb_add_word(d, SFB_LIMBS, 1, 0)
    }
}

/// Largest d with d * u4 <= Z (incl) or < Z; false when there is none
/// (d would be -1).
fn dhigh_(p: *const SfB, u4: *const SfB, incl: bool, d: *SfB) -> bool {
    var r: SfB
    sfb_divx(d, &r, p, u4)
    if sfb_is_zero(&r, SFB_LIMBS) && !incl {
        if sfb_is_zero(d, SFB_LIMBS) {
            return false
        }

        sfb_sub_one_(d)
    }

    return true
}

/// The d nearest Z / u4, ties to the even d.
fn dnear_(p: *const SfB, u4: *const SfB, d: *SfB) {
    var r:    SfB
    var half: SfB
    sfb_divx(d, &r, p, u4)
    sfb_copy(&half, u4, SFB_LIMBS)
    sfb_shr(&half, SFB_LIMBS, 1)
    var c = sfb_cmp(&r, &half, SFB_LIMBS)
    if c > 0 || c == 0 && (d->w[0] & 1) != 0 {
        sfb_add_word(d, SFB_LIMBS, 1, 0)
    }
}

fn same_(a: *const SfB, b: *const SfB) -> bool {
    return sfb_cmp(a, b, SFB_LIMBS) == 0
}

/// The next working precision: doubled, capped where the widest product
/// still fits an SfB.
fn grow_(wp: i32, zbits: i32) -> i32 {
    var cap = zbits + 2048
    if wp * 2 > cap {
        return cap
    }

    return wp * 2
}

/// floor(l2 * log10(2)) for |l2| < 2^23, possibly one low or high: the
/// callers check and step.
fn est_k_(l2: i32) -> i32 {
    var v = (l2 as i64) * 1292913987
    return (v >> 32) as i32
}

/// The round-trip digit count: floor(prec * log10(2)) + 2. 17 for
/// binary64, 36 for binary128, 73 for binary256, 149 for binary512.
pub fn sf_rt_digits(f: SfFmt) -> i32 {
    return est_k_(f.prec) + 2
}

/// The digits of v = m * 2^e (m > 0): the shortest that read back as v
/// (ndig == 0) or exactly ndig, correctly rounded, ties to even. The
/// shortest are the closest such, ties to the even digit, and are counted
/// from v's own decimal exponent (so 9e-41 beats 1e-40 when both fit,
/// as rt/fmt_exact.c does).
pub fn sf_digits(f: SfFmt, m: *const SfW, e: i32, ndig: i32, out: *SfDigits) {
    var mx: SfB
    var lx: SfB
    var hx: SfB
    sfb_zero(&mx, SFB_LIMBS)
    var nm = (f.prec + 31) / 32
    for var i: i32 = 0; i < nm; ++i {
        mx.w[i] = m->w[i]
    }

    var mbl = sfb_bitlen(&mx, SFB_LIMBS)
    // The rounding interval at exponent e - 2: [4m - 2, 4m + 2], or
    // [4m - 1, 4m + 2] when m is a power of two above the smallest normal
    // exponent (the gap below is half the gap above).
    var even = (mx.w[0] & 1) == 0
    var asym = mbl == f.prec && sfb_any_below(&mx, f.prec - 1) == false && e > f.emin - f.mbits
    sfb_copy(&lx, &mx, SFB_LIMBS)
    sfb_shl(&lx, SFB_LIMBS, 2)
    sfb_copy(&hx, &lx, SFB_LIMBS)
    sfb_add_word(&hx, SFB_LIMBS, 2, 0)
    var lsub: SfB
    sfb_set_u32(&lsub, 2)
    if asym {
        lsub.w[0] = 1
    }

    sfb_sub(&lx, &lsub, SFB_LIMBS)
    var vx: SfB
    sfb_copy(&vx, &mx, SFB_LIMBS)
    sfb_shl(&vx, SFB_LIMBS, 2)

    var shortest     = ndig == 0
    var nmax         = if shortest => sf_rt_digits(f) + 2 else => ndig
    var k            = est_k_(e + mbl - 1)
    var zbits        = (nmax + 3) * 10 / 3 + 8
    var wp           = zbits + 64
    var vlo:     SfB
    var vhi:     SfB
    var llo:     SfB
    var lhi:     SfB
    var hlo:     SfB
    var hhi:     SfB
    var t1:      SfB
    var t2:      SfB
    var u4:      SfB
    var a:       SfB
    var b:       SfB
    var dl:      SfB
    var dh:      SfB
    var dv:      SfB
    var steps:   i32 = 0
    while true {
        steps += 1
        if steps > 1 {
            wp = grow_(wp, zbits)
        }

        var t = nmax - 1 - k
        scale_(&vx, e - 2, t, wp, &vlo, &vhi)
        // k is right when 10^(nmax - 1) <= v * 10^t < 10^nmax.
        sfb_pow10(&t1, nmax - 1)
        sfb_shl(&t1, SFB_LIMBS, 2)
        sfb_pow10(&t2, nmax)
        sfb_shl(&t2, SFB_LIMBS, 2)
        if sfb_cmp(&vlo, &t2, SFB_LIMBS) >= 0 {
            k += 1
            continue
        }

        if sfb_cmp(&vhi, &t1, SFB_LIMBS) < 0 {
            k -= 1
            continue
        }

        if (sfb_cmp(&vhi, &t2, SFB_LIMBS) >= 0 || sfb_cmp(&vlo, &t1, SFB_LIMBS) < 0)
            && steps <= 12 {
            continue
        }

        if !shortest {
            sfb_set_u32(&u4, 4)
            dnear_(&vlo, &u4, &a)
            dnear_(&vhi, &u4, &b)
            if !same_(&a, &b) && steps <= 12 {
                continue
            }

            // 99.95 at 3 digits is 1.00e2: the rounding carried into a new
            // digit, so there is one decimal exponent more.
            sfb_pow10(&t1, ndig)
            if sfb_cmp(&a, &t1, SFB_LIMBS) >= 0 {
                sfb_div_small(&a, SFB_LIMBS, 10)
                k += 1
            }

            write_digits_(&a, ndig, out)
            out->k = k
            return
        }

        scale_(&lx, e - 2, t, wp, &llo, &lhi)
        scale_(&hx, e - 2, t, wp, &hlo, &hhi)
        // The largest j (fewest digits) with a multiple of 10^j inside
        // [L, H]; existence only gets easier as j falls.
        var jl:    i32 = 0
        var jh:    i32 = nmax - 1
        var unsure     = false
        while jl < jh {
            var mid = (jl + jh + 1) / 2
            var ex  = exists_(&llo, &lhi, &hlo, &hhi, mid, even, &u4, &dl, &dh)
            if ex < 0 {
                unsure = true
                break
            }

            if ex == 1 {
                jl = mid
            } else {
                jh = mid - 1
            }
        }

        if unsure && steps <= 12 {
            continue
        }

        var ex0 = exists_(&llo, &lhi, &hlo, &hhi, jl, even, &u4, &dl, &dh)
        if ex0 != 1 && steps <= 12 {
            continue
        }

        // The candidate nearest v, kept inside [dl, dh].
        dnear_(&vlo, &u4, &a)
        dnear_(&vhi, &u4, &b)
        if !same_(&a, &b) && steps <= 12 {
            continue
        }

        if sfb_cmp(&a, &dl, SFB_LIMBS) < 0 {
            sfb_copy(&a, &dl, SFB_LIMBS)
        }

        if sfb_cmp(&a, &dh, SFB_LIMBS) > 0 {
            sfb_copy(&a, &dh, SFB_LIMBS)
        }

        // a * 10^(jl - t): its digits, trailing zeros dropped.
        write_digits_(&a, 0, out)
        var len = out->n
        out->k = len - 1 + jl - t
        while out->n > 1 && out->d[out->n - 1] == 48 {
            out->n -= 1
        }

        return
    }
}

/// Whether a multiple of 10^j lies in [L, H] (bounds inclusive when
/// `incl`): 1 yes, 0 no, -1 the two ends of an interval disagree. dl and
/// dh get the first and last such multiple's index; u4 gets 4 * 10^j.
fn exists_(llo:  *const SfB,
           lhi:  *const SfB,
           hlo:  *const SfB,
           hhi:  *const SfB,
           j:    i32,
           incl: bool,
           u4:   *SfB,
           dl:   *SfB,
           dh:   *SfB) -> i32 {
    var a: SfB
    var b: SfB
    sfb_pow10(u4, j)
    sfb_shl(u4, SFB_LIMBS, 2)
    dlow_(llo, u4, incl, dl)
    dlow_(lhi, u4, incl, &a)
    if !same_(dl, &a) {
        return -1
    }

    var ok1 = dhigh_(hlo, u4, incl, dh)
    var ok2 = dhigh_(hhi, u4, incl, &b)
    if ok1 != ok2 {
        return -1
    }

    if ok1 && !same_(dh, &b) {
        return -1
    }

    if !ok1 {
        return 0
    }

    return if sfb_cmp(dl, dh, SFB_LIMBS) <= 0 => 1 else => 0
}

/// a's decimal digits into out (a > 0 consumed), zero-padded on the left
/// to `width` when width > 0.
fn write_digits_(a: *SfB, width: i32, out: *SfDigits) {
    var tmp: [u8; 640]
    var n:   i32       = 0
    while !sfb_is_zero(a, SFB_LIMBS) && n < 630 {
        var r = sfb_div_small(a, SFB_LIMBS, 1000000000)
        for var i: i32 = 0; i < 9; ++i {
            tmp[n] = (48 + r % 10) as u8
            r      = r / 10
            n += 1
        }
    }

    while n > 1 && tmp[n - 1] == 48 {
        n -= 1
    }

    while n < width {
        tmp[n] = 48
        n += 1
    }

    for var i: i32 = 0; i < n; ++i {
        out->d[i] = tmp[n - 1 - i]
    }

    out->n = n
}

// === layout =================================================================
//
// rt/fmt_layout.c's layouts, byte for byte: 'e'/'E' is d[.ddd]e+XX with at
// least two exponent digits; 'g' is fixed notation unless the exponent is
// < -4 or >= its threshold, and drops trailing zeros in the precision form.

/// Output under construction, bounded by cap (bytes past it are counted,
/// not written).
struct Emit_ {
    var p:   unsafe *u8 = &null
    var cap: usize      = 0
    var pos: usize      = 0
}

fn pick_(c: bool, a: u8, b: u8) -> u8 {
    if c {
        return a
    }

    return b
}

fn put_(em: *Emit_, c: u8) {
    if em->pos < em->cap {
        unsafe {
            em->p[em->pos] = c
        }
    }

    em->pos += 1
}

fn put_exp_(em: *Emit_, e: i32, conv: u8) {
    put_(em, pick_(conv == 69, 69, 101))
    var v = e
    if v < 0 {
        put_(em, 45)
        v = -v
    } else {
        put_(em, 43)
    }

    var buf: [u8; 12]
    var n:   i32      = 0
    while v > 0 || n == 0 {
        buf[n] = (48 + v % 10) as u8
        v      = v / 10
        n += 1
    }

    if n < 2 {
        put_(em, 48)
    }

    while n > 0 {
        n -= 1
        put_(em, buf[n])
    }
}

fn layout_(em: *Emit_, d: *const SfDigits, conv: u8, p: i32) {
    var n = d->n
    var x = d->k
    if conv != 103 || x < -4 || x >= p {
        put_(em, d->d[0])
        if n > 1 {
            put_(em, 46)
            for var i: i32 = 1; i < n; ++i {
                put_(em, d->d[i])
            }
        }

        put_exp_(em, x, conv)
    } else if x < 0 {
        put_(em, 48)
        put_(em, 46)
        for var i: i32 = 0; i < -x - 1; ++i {
            put_(em, 48)
        }

        for var i: i32 = 0; i < n; ++i {
            put_(em, d->d[i])
        }
    } else if n <= x + 1 {
        for var i: i32 = 0; i < n; ++i {
            put_(em, d->d[i])
        }

        for var i: i32 = 0; i < x + 1 - n; ++i {
            put_(em, 48)
        }
    } else {
        for var i: i32 = 0; i < x + 1; ++i {
            put_(em, d->d[i])
        }

        put_(em, 46)
        for var i: i32 = x + 1; i < n; ++i {
            put_(em, d->d[i])
        }
    }
}

/// |a| as text into out[0..cap), rt/fmt.h's contract (the sign is the
/// caller's): conv 'g' | 'e' | 'E'; prec < 0 the shortest round-trip
/// digits, else C's precision (digits after the point for 'e',
/// significant digits for 'g'). Returns the bytes written.
pub fn sf_format(f:     SfFmt,
                 a:     *const SfW,
                 out:   unsafe *u8,
                 cap:   usize,
                 prec:  i32,
                 conv0: u8) -> i32 {
    var em   = Emit_ { p: out, cap: cap, pos: 0 }
    var conv = conv0
    if conv != 101 && conv != 69 {
        conv = 103
    }

    var x: SfU
    sf_unpack(f, a, &x)
    if x.cls == SF_INF || x.cls == SF_NAN {
        var up = conv == 69
        if x.cls == SF_INF {
            put_(&em, pick_(up, 73, 105))
            put_(&em, pick_(up, 78, 110))
            put_(&em, pick_(up, 70, 102))
        } else {
            put_(&em, pick_(up, 78, 110))
            put_(&em, pick_(up, 65, 97))
            put_(&em, pick_(up, 78, 110))
        }

        return (if em.pos < cap => em.pos else => cap) as i32
    }

    if x.cls == SF_ZERO {
        put_(&em, 48)
        if conv != 103 {
            if prec > 0 {
                put_(&em, 46)
                for var i: i32 = 0; i < prec; ++i {
                    put_(&em, 48)
                }
            }

            put_exp_(&em, 0, conv)
        }

        return (if em.pos < cap => em.pos else => cap) as i32
    }

    var dg: SfDigits
    if prec < 0 {
        sf_digits(f, &x.m, x.e, 0, &dg)
        layout_(&em, &dg, conv, sf_rt_digits(f))
    } else {
        var ndig = if conv == 103 => (if prec == 0 => 1 else => prec) else => prec + 1
        if ndig > SF_MAX_PREC {
            ndig = SF_MAX_PREC
        }

        sf_digits(f, &x.m, x.e, ndig, &dg)
        if conv == 103 {
            while dg.n > 1 && dg.d[dg.n - 1] == 48 {
                dg.n -= 1
            }
        }

        layout_(&em, &dg, conv, ndig)
    }

    return (if em.pos < cap => em.pos else => cap) as i32
}

/// Parses p[0..n) (see sf_parse) into *out as an encoding of f.
pub fn sf_parse_bits(f: SfFmt, p: *const u8, n: usize, out: *u512) -> bool {
    var r: SfW
    if !sf_parse(f, &r, p, n) {
        return false
    }

    *out = sf_store(f, &r)
    return true
}

/// sf_format on an encoding.
pub fn sf_format_bits(f: SfFmt, a: u512, out: unsafe *u8, cap: usize, prec: i32, conv: u8) -> i32 {
    var x: SfW
    sf_load(f, &x, a)
    return sf_format(f, &x, out, cap, prec, conv)
}
