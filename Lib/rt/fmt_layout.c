/* --- The Kairo Project ----------------------- Lib/rt/fmt_layout.c --- */
/*
 *   Digits -> text: C's 'e' and 'g' layouts, the shortest form without
 *   per-byte checks, and format_float, which picks a digit generator
 *   (fmt_dragonbox*.c or fmt_exact.c) and lays its digits out.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt_impl.h"

#include <string.h>

/* ===================================================================== */
/*  Layout                                                                */
/* ===================================================================== */

typedef struct {
    unsigned char *out;
    size_t         cap;
    size_t         pos;
} emitter;

static inline void emit(emitter *em, unsigned char c) {
    if (em->pos < em->cap) em->out[em->pos] = c;
    ++em->pos;
}

static void emit_n(emitter *em, const unsigned char *p, size_t n) {
    size_t room = em->pos < em->cap ? em->cap - em->pos : 0;
    if (n < room) room = n;
    memcpy(em->out + em->pos, p, room);
    em->pos += n;
}

static void emit_zeros(emitter *em, int n) {
    while (n-- > 0) emit(em, '0');
}

static const unsigned char radix100[201] =
    "00010203040506070809101112131415161718192021222324252627282930313233343536373839"
    "40414243444546474849505152535455565758596061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899";

static inline void put2(unsigned char *w, uint32_t n) { memcpy(w, radix100 + 2 * n, 2); }

/* n in [1, 10^9) as ASCII, forward; returns the digit count. James Anhalt's
 * itoa idea as Dragonbox's to_chars uses it: find y with
 * floor(10^k y / 2^32) = n, then each (y mod 2^32) * 100 yields the next
 * two digits in its top word. No division. */
static int digits_u32(uint32_t n, unsigned char *w) {
    uint64_t prod;
    uint32_t head;
    int      len;
    if (n >= UINT32_C(100000000)) {            /* 9 digits: 1441151882 = ceil(2^57 / 10^8) + 1 */
        prod = (n * UINT64_C(1441151882)) >> 25;
        head = (uint32_t)(prod >> 32);
        len  = 9;
    } else if (n >= UINT32_C(1000000)) {       /* 7 or 8: 281474978 = ceil(2^48 / 10^6) + 1 */
        prod = (n * UINT64_C(281474978)) >> 16;
        head = (uint32_t)(prod >> 32);
        len  = 7;
    } else if (n >= 10000) {                   /* 5 or 6: 429497 = ceil(2^32 / 10^4) */
        prod = n * UINT64_C(429497);
        head = (uint32_t)(prod >> 32);
        len  = 5;
    } else if (n >= 100) {                     /* 3 or 4: 42949673 = ceil(2^32 / 10^2) */
        prod = n * UINT64_C(42949673);
        head = (uint32_t)(prod >> 32);
        len  = 3;
    } else {
        prod = 0;
        head = n;
        len  = 1;
    }
    if (head >= 10) { put2(w, head); w += 2; ++len; }
    else            { *w++ = (unsigned char)('0' + head); }
    for (n = (uint32_t)(len - 1) / 2; n > 0; --n) {
        prod = (prod & UINT32_C(0xffffffff)) * 100;
        put2(w, (uint32_t)(prod >> 32));
        w += 2;
    }
    return len;
}

/* v in [1, 10^17] as ASCII, forward; returns the digit count. */
static int digits_u64(uint64_t v, unsigned char *w) {
    if (v >= UINT64_C(100000000)) {
        /* A block of up to nine digits, then exactly eight. */
        uint32_t hi  = (uint32_t)(v / UINT64_C(100000000));
        uint32_t lo  = (uint32_t)v - hi * UINT32_C(100000000);
        int      len = digits_u32(hi, w);
        uint64_t prod = ((lo * UINT64_C(281474978)) >> 16) + 1;
        int      i;
        w += len;
        for (i = 0; i < 4; ++i) {
            put2(w, (uint32_t)(prod >> 32));
            w += 2;
            prod = (prod & UINT32_C(0xffffffff)) * 100;
        }
        return len + 8;
    }
    return digits_u32((uint32_t)v, w);
}

static void emit_exponent(emitter *em, int e, unsigned char conv) {
    unsigned char buf[24];
    int n;
    emit(em, conv == 'E' ? 'E' : 'e');
    if (e < 0) { emit(em, '-'); e = -e; } else { emit(em, '+'); }
    n = digits_u32((uint32_t)e, buf);
    if (n < 2) emit(em, '0');
    emit_n(em, buf, (size_t)n);
}

/* digits[0..n) with the value d0.d1d2... * 10^exp10. sci forces 'e' form;
 * otherwise 'g' with threshold p: fixed unless exp10 < -4 or exp10 >= p. */
static void layout(emitter *em, const unsigned char *digits, int n, int exp10, unsigned char conv, int p) {
    if (conv != 'g' || exp10 < -4 || exp10 >= p) {
        emit(em, digits[0]);
        if (n > 1) {
            emit(em, '.');
            emit_n(em, digits + 1, (size_t)(n - 1));
        }
        emit_exponent(em, exp10, conv);
    } else if (exp10 < 0) {
        emit(em, '0');
        emit(em, '.');
        emit_zeros(em, -exp10 - 1);
        emit_n(em, digits, (size_t)n);
    } else if (n <= exp10 + 1) {
        emit_n(em, digits, (size_t)n);
        emit_zeros(em, exp10 + 1 - n);
    } else {
        emit_n(em, digits, (size_t)(exp10 + 1));
        emit(em, '.');
        emit_n(em, digits + exp10 + 1, (size_t)(n - exp10 - 1));
    }
}

/* ===================================================================== */
/*  The formatters                                                        */
/* ===================================================================== */

#if defined(__GNUC__) || defined(__clang__)
static inline int clz64(uint64_t v) { return __builtin_clzll(v); }
#else
static inline int clz64(uint64_t v) { int n = 0; while (!(v >> 63)) { v <<= 1; ++n; } return n; }
#endif

/* Digit count of v in [1, 10^17]: the estimate from the bit length is exact
 * or one low, and one compare settles it. */
static int digit_count_u64(uint64_t v) {
    static const uint64_t pow10[20] = {
        UINT64_C(1), UINT64_C(10), UINT64_C(100), UINT64_C(1000), UINT64_C(10000), UINT64_C(100000),
        UINT64_C(1000000), UINT64_C(10000000), UINT64_C(100000000), UINT64_C(1000000000),
        UINT64_C(10000000000), UINT64_C(100000000000), UINT64_C(1000000000000),
        UINT64_C(10000000000000), UINT64_C(100000000000000), UINT64_C(1000000000000000),
        UINT64_C(10000000000000000), UINT64_C(100000000000000000), UINT64_C(1000000000000000000),
        UINT64_C(10000000000000000000)
    };
    int n = (((63 - clz64(v)) * 1233) >> 12) + 1;
    return n + (v >= pow10[n]);
}

/* n digits at w: from sig when dg is null, else copied from dg. */
static inline void put_digits(unsigned char *w, uint64_t sig, const unsigned char *dg, int n) {
    if (dg == NULL) digits_u64(sig, w);
    else            memcpy(w, dg, (size_t)n);
}

/* The shortest form, laid out without per-byte checks: the text is at most
 * 43 bytes (36 digits, point, e, sign, four exponent digits) and lands in
 * out directly when out is big enough, else in a scratch that is cut down.
 * The digits come from sig (Dragonbox) or from dg (the exact path). */
static int layout_short(unsigned char *out, size_t cap, uint64_t sig, const unsigned char *dg, int n,
                        int exp10, unsigned char conv, int p) {
    unsigned char  scratch[64];
    unsigned char *dst = cap >= sizeof scratch ? out : scratch;
    unsigned char *w = dst;
    size_t         len;
    int            i;

    if (conv != 'g' || exp10 < -4 || exp10 >= p) {
        /* d.ddd: write the digits one byte to the right, then the leading
         * digit is already where the point goes and moves once. */
        int e = exp10;
        put_digits(w + 1, sig, dg, n);
        w[0] = w[1];
        if (n > 1) { w[1] = '.'; w += n + 1; }
        else       { w += 1; }
        *w++ = conv == 'E' ? 'E' : 'e';
        if (e < 0) { *w++ = '-'; e = -e; } else { *w++ = '+'; }
        if (e >= 100) {
            int hi = e / 100;
            if (hi >= 10) { put2(w, (uint32_t)hi); w += 2; }
            else          { *w++ = (unsigned char)('0' + hi); }
            e -= hi * 100;
        }
        put2(w, (uint32_t)e);
        w += 2;
    } else if (exp10 < 0) {
        *w++ = '0';
        *w++ = '.';
        for (i = -exp10 - 1; i > 0; --i) *w++ = '0';
        put_digits(w, sig, dg, n);
        w += n;
    } else if (n <= exp10 + 1) {
        put_digits(w, sig, dg, n);
        w += n;
        for (i = exp10 + 1 - n; i > 0; --i) *w++ = '0';
    } else {
        /* ddd.ddd: the fraction moves right by one for the point. */
        put_digits(w, sig, dg, n);
        memmove(w + exp10 + 2, w + exp10 + 1, (size_t)(n - exp10 - 1));
        w[exp10 + 1] = '.';
        w += n + 1;
    }
    len = (size_t)(w - dst);
    if (len > cap) len = cap;
    if (dst != out) memcpy(out, scratch, len);
    return (int)len;
}

int kairo_rt_fmt_write_shortest_(unsigned char *out, size_t cap, db_dec d, unsigned char conv, int p) {
    int n = digit_count_u64(d.sig);
    return layout_short(out, cap, d.sig, NULL, n, n - 1 + d.exp, conv == 'e' || conv == 'E' ? conv : 'g', p);
}

/* fast: 0, 32 or 64, the Dragonbox path usable for the shortest form of
 * this value; bits is the pattern it takes. max_digits is the format's P. */
int kairo_rt_fmt_format_float_(unsigned char *out, size_t cap, const fclass *f, uint64_t bits, int fast,
                        int max_digits, int prec, unsigned char conv) {
    emitter em;
    em.out = out;
    em.cap = cap;
    em.pos = 0;

    if (conv != 'e' && conv != 'E') conv = 'g';

    if (f->cls == FC_INF || f->cls == FC_NAN) {
        static const unsigned char words[4][4] = { "inf", "nan", "INF", "NAN" };
        emit_n(&em, words[(f->cls == FC_NAN) + 2 * (conv == 'E')], 3);
        return (int)(em.pos < cap ? em.pos : cap);
    }

    if (f->cls == FC_ZERO) {
        emit(&em, '0');
        if (conv != 'g') {
            if (prec > 0) { emit(&em, '.'); emit_zeros(&em, prec); }
            emit_exponent(&em, 0, conv);
        }
        return (int)(em.pos < cap ? em.pos : cap);
    }

    if (prec < 0) {
        if (fast == 32) return kairo_rt_fmt_write_shortest_(out, cap, kairo_rt_fmt_db32_to_decimal_((uint32_t)bits), conv, max_digits);
        if (fast == 64) return kairo_rt_fmt_write_shortest_(out, cap, kairo_rt_fmt_db64_to_decimal_(bits), conv, max_digits);
        {
            unsigned char digits[48];
            exact_ws      w;
            int           n, k;
            n = kairo_rt_fmt_exact_shortest_(&f->v, digits, &k, &w);
            return layout_short(out, cap, 0, digits, n, k - 1, conv, max_digits);
        }
    } else {
        /* 'e' wants prec digits after the point, 'g' wants prec significant
         * digits and then drops the trailing zeros. */
        unsigned char  stack_digits[128];
        unsigned char *digits = stack_digits;
        exact_ws       w;
        int            ndig = conv == 'g' ? (prec == 0 ? 1 : prec) : prec + 1;
        int            n, k;

        if (ndig > (int)sizeof stack_digits) {
            digits = kairo_rt_fmt_alloc((size_t)ndig);
            if (digits == NULL) return 0;
        }
        n = kairo_rt_fmt_exact_fixed_(&f->v, ndig, digits, &k, &w);
        if (conv == 'g') {
            while (n > 1 && digits[n - 1] == '0') --n;
        }
        layout(&em, digits, n, k - 1, conv, ndig);
        if (digits != stack_digits) kairo_rt_fmt_free(digits);
    }
    return (int)(em.pos < cap ? em.pos : cap);
}
