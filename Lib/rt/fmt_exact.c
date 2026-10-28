/* --- The Kairo Project ------------------------ Lib/rt/fmt_exact.c --- */
/*
 *   Exact digits for every format: a small bignum, the shortest
 *   digits (Burger & Dybvig free-format, Dragonbox's tie rule) and
 *   fixed precision by long division. Slow by Dragonbox's standard,
 *   exact by any.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt_impl.h"

#include <string.h>

/* ===================================================================== */
/*  Exact digits: a small bignum                                          */
/* ===================================================================== */

static void bn_set_u128(bn *a, u128 v) {
    a->d[0] = (uint32_t)v.lo;
    a->d[1] = (uint32_t)(v.lo >> 32);
    a->d[2] = (uint32_t)v.hi;
    a->d[3] = (uint32_t)(v.hi >> 32);
    a->n = 4;
    while (a->n > 0 && a->d[a->n - 1] == 0) --a->n;
}

static void bn_set_u32(bn *a, uint32_t v) {
    a->d[0] = v;
    a->n = v != 0;
}

static void bn_copy(bn *dst, const bn *src) {
    dst->n = src->n;
    memcpy(dst->d, src->d, (size_t)src->n * sizeof(uint32_t));
}

static void bn_shl(bn *a, int bits) {
    int limbs = bits >> 5, sh = bits & 31, i;
    if (a->n == 0) return;
    if (sh != 0) {
        uint32_t carry = 0;
        for (i = 0; i < a->n; ++i) {
            uint32_t v = a->d[i];
            a->d[i] = (v << sh) | carry;
            carry = v >> (32 - sh);
        }
        if (carry) a->d[a->n++] = carry;
    }
    if (limbs != 0) {
        memmove(a->d + limbs, a->d, (size_t)a->n * sizeof(uint32_t));
        memset(a->d, 0, (size_t)limbs * sizeof(uint32_t));
        a->n += limbs;
    }
}

static void bn_mul_u32(bn *a, uint32_t m) {
    uint64_t carry = 0;
    int i;
    for (i = 0; i < a->n; ++i) {
        uint64_t p = (uint64_t)a->d[i] * m + carry;
        a->d[i] = (uint32_t)p;
        carry = p >> 32;
    }
    if (carry) a->d[a->n++] = (uint32_t)carry;
}

static void bn_mul_pow10(bn *a, int k) {
    static const uint32_t pow10[10] = { 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000 };
    while (k >= 9) { bn_mul_u32(a, UINT32_C(1000000000)); k -= 9; }
    if (k > 0) bn_mul_u32(a, pow10[k]);
}

static int bn_cmp(const bn *a, const bn *b) {
    int i;
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (i = a->n - 1; i >= 0; --i) {
        if (a->d[i] != b->d[i]) return a->d[i] < b->d[i] ? -1 : 1;
    }
    return 0;
}

/* a += b */
static void bn_add(bn *a, const bn *b) {
    uint64_t carry = 0;
    int i, n = a->n > b->n ? a->n : b->n;
    for (i = 0; i < n; ++i) {
        uint64_t s = carry + (i < a->n ? a->d[i] : 0) + (i < b->n ? b->d[i] : 0);
        a->d[i] = (uint32_t)s;
        carry = s >> 32;
    }
    a->n = n;
    if (carry) a->d[a->n++] = (uint32_t)carry;
}

/* a -= b, requires a >= b */
static void bn_sub(bn *a, const bn *b) {
    int64_t borrow = 0;
    int i;
    for (i = 0; i < a->n; ++i) {
        int64_t s = (int64_t)a->d[i] - (i < b->n ? b->d[i] : 0) - borrow;
        borrow = s < 0;
        a->d[i] = (uint32_t)(s + (borrow << 32));
    }
    while (a->n > 0 && a->d[a->n - 1] == 0) --a->n;
}

/* compare a + b against c */
static int bn_cmp_sum(const bn *a, const bn *b, const bn *c, bn *scratch) {
    bn_copy(scratch, a);
    bn_add(scratch, b);
    return bn_cmp(scratch, c);
}

/* a -= q * b, requires a >= q * b */
static void bn_submul(bn *a, const bn *b, uint32_t q) {
    uint64_t carry = 0;
    int64_t  borrow = 0;
    int i;
    for (i = 0; i < a->n; ++i) {
        uint64_t p = (i < b->n ? (uint64_t)b->d[i] * q : 0) + carry;
        int64_t  s = (int64_t)a->d[i] - (uint32_t)p - borrow;
        carry = p >> 32;
        borrow = s < 0;
        a->d[i] = (uint32_t)(s + (borrow << 32));
    }
    while (a->n > 0 && a->d[a->n - 1] == 0) --a->n;
}

/* Shift a and b so that b's top limb has its high bit set: the quotient
 * estimate below is then never more than one low. Ratios are unchanged. */
static int bn_normalize_shift(const bn *b) {
    uint32_t top = b->d[b->n - 1];
    int sh = 0;
    while (!(top & UINT32_C(0x80000000))) { top <<= 1; ++sh; }
    return sh;
}

/* q = floor(a / b) for a < 10 b and b normalized; a becomes the remainder.
 * With B = b's top limb >= 2^31 and A = a's limbs above the same position,
 * floor(A / (B + 1)) is q or q - 1, so one multiply-subtract and at most
 * one correction replace up to nine subtractions. */
static int bn_divmod_digit(bn *a, const bn *b) {
    uint64_t A;
    int q;
    if (a->n < b->n) return 0;
    A = a->n > b->n ? ((uint64_t)a->d[a->n - 1] << 32) | a->d[a->n - 2] : a->d[a->n - 1];
    q = (int)(A / ((uint64_t)b->d[b->n - 1] + 1));
    if (q > 0) bn_submul(a, b, (uint32_t)q);
    while (bn_cmp(a, b) >= 0) {
        bn_sub(a, b);
        ++q;
    }
    return q;
}

static int bitlen_u128(u128 m) {
    uint64_t v = m.hi ? m.hi : m.lo;
    int n = m.hi ? 64 : 0;
    while (v) { ++n; v >>= 1; }
    return n;
}
/* floor(log10(v)) + 1 or one less: the estimate the fixups below correct. */
static int estimate_k(const fval *v) {
    int l2 = v->e + bitlen_u128(v->m) - 1;              /* 2^l2 <= v < 2^(l2+1) */
    double l = (double)l2 * 0.30102999566398119521;     /* < 5e-12 off; no n*log10(2) is that near an integer for |n| < 2^15 */
    int f = (int)l;
    if ((double)f > l) --f;
    return f + 1;
}
/* Shortest digits that read back as v under nearest-to-even, ties to the
 * even digit. Writes ASCII digits, returns the count n and k such that
 * v ~ 0.d1...dn * 10^k. Burger & Dybvig's free-format algorithm with the
 * "both ends fit" case rounding to even instead of up. */
int kairo_rt_fmt_exact_shortest_(const fval *v, unsigned char *digits, int *k_out, exact_ws *w) {
    bn *r = &w->r, *s = &w->s, *mp = &w->mp, *mm = &w->mm, *t = &w->t;
    int even = (v->m.lo & 1) == 0;
    int is_pow2 = bitlen_u128(v->m) == v->p &&
                  (v->p <= 64 ? v->m.lo == (UINT64_C(1) << (v->p - 1)) && v->m.hi == 0
                              : v->m.lo == 0 && v->m.hi == (UINT64_C(1) << (v->p - 65)));
    int est, k, n = 0;

    /* The interval [v - mm, v + mp] scaled so that mp and mm are integers;
     * a power of two has a closer lower neighbour, except at the bottom of
     * the normal range where the subnormal gap is the same size. */
    bn_set_u128(r, v->m);
    if (v->e >= 0) {
        if (!is_pow2) {
            bn_shl(r, v->e + 1); bn_set_u32(s, 2);
            bn_set_u32(mp, 1); bn_shl(mp, v->e); bn_copy(mm, mp);
        } else {
            bn_shl(r, v->e + 2); bn_set_u32(s, 4);
            bn_set_u32(mp, 1); bn_shl(mp, v->e + 1);
            bn_set_u32(mm, 1); bn_shl(mm, v->e);
        }
    } else {
        if (v->e == v->e_min || !is_pow2) {
            bn_shl(r, 1); bn_set_u32(s, 1); bn_shl(s, 1 - v->e);
            bn_set_u32(mp, 1); bn_set_u32(mm, 1);
        } else {
            bn_shl(r, 2); bn_set_u32(s, 1); bn_shl(s, 2 - v->e);
            bn_set_u32(mp, 2); bn_set_u32(mm, 1);
        }
    }

    est = estimate_k(v);
    if (est >= 0) {
        bn_mul_pow10(s, est);
    } else {
        bn_mul_pow10(r, -est);
        bn_mul_pow10(mp, -est);
        bn_mul_pow10(mm, -est);
    }

    {
        int sh = bn_normalize_shift(s);
        bn_shl(r, sh); bn_shl(s, sh); bn_shl(mp, sh); bn_shl(mm, sh);
    }

    /* Fixup. Burger & Dybvig also jump to est + 1 when only the interval's
     * TOP reaches 10^est, which returns 10^est whenever it fits, even when a
     * one-digit value below it is closer (2^-133 as bf16 is 9.18e-41; the
     * interval holds both 9e-41 and 1e-40). Generating at est instead ends
     * on the first digit in that case, and that digit rolling to ten IS
     * 10^est, so nothing is lost and the closer candidate wins. */
    if (bn_cmp(r, s) >= 0) {
        k = est + 1;
    } else {
        k = est;
        bn_mul_u32(r, 10); bn_mul_u32(mp, 10); bn_mul_u32(mm, 10);
    }

    for (;;) {
        int d   = bn_divmod_digit(r, s);
        int tc1 = bn_cmp(r, mm) < (even ? 1 : 0);               /* r <= mm, or r < mm */
        int tc2 = bn_cmp_sum(r, mp, s, t) >= (even ? 0 : 1);     /* r + mp >= s, or > s */
        if (!tc1 && !tc2) {
            digits[n++] = (unsigned char)('0' + d);
            bn_mul_u32(r, 10); bn_mul_u32(mp, 10); bn_mul_u32(mm, 10);
            continue;
        }
        if (tc1 && tc2) {
            int c;
            bn_shl(r, 1);
            c = bn_cmp(r, s);
            if (c > 0 || (c == 0 && (d & 1))) ++d;
        } else if (tc2) {
            ++d;
        }
        if (d == 10) {           /* only possible on the first digit: the value is 10^k */
            d = 1;
            ++k;
        }
        digits[n++] = (unsigned char)('0' + d);
        break;
    }
    *k_out = k;
    return n;
}

/* Exactly ndig significant digits of v, the last rounded to nearest with
 * ties to even. Same output convention as kairo_rt_fmt_exact_shortest_. */
int kairo_rt_fmt_exact_fixed_(const fval *v, int ndig, unsigned char *digits, int *k_out, exact_ws *w) {
    bn *r = &w->r, *s = &w->s;
    int k, i, c;

    bn_set_u128(r, v->m);
    bn_set_u32(s, 1);
    if (v->e >= 0) bn_shl(r, v->e); else bn_shl(s, -v->e);

    /* Scale to 1 <= r/s < 10; the estimate may be one low. */
    k = estimate_k(v);
    if (k - 1 >= 0) bn_mul_pow10(s, k - 1); else bn_mul_pow10(r, 1 - k);
    bn_copy(&w->t, s);
    bn_mul_u32(&w->t, 10);
    if (bn_cmp(r, &w->t) >= 0) {
        bn_copy(s, &w->t);
        ++k;
    }
    {
        int sh = bn_normalize_shift(s);
        bn_shl(r, sh); bn_shl(s, sh);
    }

    for (i = 0; i < ndig; ++i) {
        digits[i] = (unsigned char)('0' + bn_divmod_digit(r, s));
        bn_mul_u32(r, 10);
    }

    /* r is now 10 * remainder; the half point is 5 * s. */
    bn_copy(&w->t, s);
    bn_mul_u32(&w->t, 5);
    c = bn_cmp(r, &w->t);
    if (c > 0 || (c == 0 && (digits[ndig - 1] & 1))) {
        for (i = ndig - 1; i >= 0; --i) {
            if (digits[i] != '9') { ++digits[i]; break; }
            digits[i] = '0';
        }
        if (i < 0) {           /* 999... rolled over */
            digits[0] = '1';
            ++k;
        }
    }
    *k_out = k;
    return ndig;
}
