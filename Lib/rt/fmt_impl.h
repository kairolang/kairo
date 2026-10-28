/* --- The Kairo Project ------------------------- Lib/rt/fmt_impl.h --- */
/*
 *   Internal to Lib/rt's fmt_*.c: the types and helpers more than one of
 *   them uses. Not an API -- nothing outside Lib/rt includes it, and the
 *   builtin imports rt/fmt.h only.
 *
 *   Float text for every Kairo float format, and the heap fmt_buf.k draws on.
 *
 *   Two digit generators sit behind one layout routine:
 *
 *     Dragonbox   f32 and f64, shortest round-trip. A port of Junekey Jeon's
 *                 jk-jeon/dragonbox to_decimal with its default policies:
 *                 nearest-to-even reading, ties to even, trailing zeros
 *                 removed, full cache. Directed-rounding readers and the
 *                 compressed cache are not ported; nothing in the runtime
 *                 reads under a directed mode. The comments that carry the
 *                 mathematics are the paper's. Agrees with the original on
 *                 every binary32 pattern; the digit and layout code after
 *                 it is Lib/rt's own.
 *
 *     exact       everything else: shortest for f16/bf16/f8/f80/f128, and
 *                 every fixed-precision request for every format. Bignum
 *                 free-format (Burger & Dybvig) with Dragonbox's tie rule,
 *                 long division for fixed precision. Slow by Dragonbox's
 *                 standard, exact by any.
 *
 *   One file per family:
 *     fmt_alloc.c        the heap FmtBuf draws on
 *     fmt_dragonbox32.c  shortest digits, binary32
 *     fmt_dragonbox64.c  shortest digits, binary64
 *     fmt_exact.c        the bignum, exact shortest and fixed digits
 *     fmt_decode.c       a bit pattern -> fclass
 *     fmt_layout.c       digits -> text, and format_float over all of it
 *     fmt_float.c        the kairo_rt_fmt_<format> entry points
 *
 *   The Dragonbox port and its cache tables derive from jk-jeon/dragonbox,
 *   Copyright 2020-2025 Junekey Jeon, used under the Boost Software License
 *   1.0 (alternatively Apache-2.0 WITH LLVM-exception).
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_FMT_IMPL_H
#define KAIRO_RT_FMT_IMPL_H

#include "rt/fmt.h"

#include <stddef.h>
#include <stdint.h>

_Static_assert(((-1) >> 1) == -1, "the log formulas below need an arithmetic right shift");

/* ===================================================================== */
/*  Wide multiply                                                         */
/* ===================================================================== */

typedef struct { uint64_t hi, lo; } u128;

#if defined(__SIZEOF_INT128__)
__extension__ typedef unsigned __int128 u128_native;
static inline u128 umul128(uint64_t a, uint64_t b) {
    u128_native r = (u128_native)a * b;
    u128 o;
    o.hi = (uint64_t)(r >> 64);
    o.lo = (uint64_t)r;
    return o;
}
static inline uint64_t umul128_hi(uint64_t a, uint64_t b) {
    return (uint64_t)(((u128_native)a * b) >> 64);
}
#else
static inline u128 umul128(uint64_t x, uint64_t y) {
    uint64_t a = x >> 32, b = (uint32_t)x, c = y >> 32, d = (uint32_t)y;
    uint64_t ac = a * c, bc = b * c, ad = a * d, bd = b * d;
    uint64_t mid = (bd >> 32) + (uint32_t)ad + (uint32_t)bc;
    u128 o;
    o.hi = ac + (mid >> 32) + (ad >> 32) + (bc >> 32);
    o.lo = (mid << 32) | (uint32_t)bd;
    return o;
}
static inline uint64_t umul128_hi(uint64_t x, uint64_t y) { return umul128(x, y).hi; }
#endif

/* ===================================================================== */
/*  Dragonbox, both formats                                              */
/* ===================================================================== */

/* floor(log10(2^e)) etc. as multiply-shift. The magic numbers are the
 * widest tier of the original; each is exact on the range noted, which
 * covers every exponent either format can produce. */
static inline int floor_log10_pow2(int e)               { return (e * 315653) >> 20; }          /* |e| <= 2620       */
static inline int floor_log2_pow10(int k)               { return (k * 1741647) >> 19; }         /* |k| <= 1233       */
static inline int floor_log10_pow2_minus_log10_4_3(int e) { return (e * 631305 - 261663) >> 21; } /* -2985 <= e <= 2936 */

static inline uint32_t rotr32(uint32_t n, unsigned r) { r &= 31; return (n >> r) | (n << ((32 - r) & 31)); }
static inline uint64_t rotr64(uint64_t n, unsigned r) { r &= 63; return (n >> r) | (n << ((64 - r) & 63)); }

typedef struct { uint64_t sig; int exp; } db_dec;   /* value = sig * 10^exp */

/* ===================================================================== */
/*  The exact path's types                                               */
/* ===================================================================== */

/* Limb budget. The worst case is the smallest binary128 subnormal, 2^-16494:
 * the scaled remainder reaches m * 2^2 * 10^4966 < 2^16612 bits, and one
 * more decade during generation. 640 limbs is 20480 bits. */
#define BN_LIMBS 640

typedef struct {
    int      n;              /* limbs in use; d[n-1] != 0 unless n == 0 */
    uint32_t d[BN_LIMBS];
} bn;

/* A decoded finite nonzero value: v = m * 2^e, of a format with p
 * significand bits (hidden bit included) whose subnormals sit at e_min. */
typedef struct {
    u128 m;
    int  e;
    int  p;
    int  e_min;
} fval;

/* The scratch every exact routine works in. Off the stack: ~13 KB. */
typedef struct { bn r, s, mp, mm, t; } exact_ws;

/* ===================================================================== */
/*  A decoded value                                                      */
/* ===================================================================== */

enum { FC_FINITE, FC_ZERO, FC_INF, FC_NAN };

typedef struct {
    int  cls;
    fval v;
} fclass;

/* ===================================================================== */
/*  Across files                                                         */
/* ===================================================================== */

/* fmt_dragonbox32.c / fmt_dragonbox64.c. Nonzero finite only. */
db_dec kairo_rt_fmt_db32_to_decimal_(uint32_t bits);
db_dec kairo_rt_fmt_db64_to_decimal_(uint64_t bits);

/* fmt_exact.c */
int kairo_rt_fmt_exact_shortest_(const fval *v, unsigned char *digits, int *k_out, exact_ws *w);
int kairo_rt_fmt_exact_fixed_(const fval *v, int ndig, unsigned char *digits, int *k_out, exact_ws *w);

/* fmt_decode.c */
fclass kairo_rt_fmt_decode_ieee_(uint64_t hi, uint64_t lo, int mant_bits, int exp_bits, int finite_only);
fclass kairo_rt_fmt_decode_x87_(uint64_t mant, unsigned se);

/* fmt_layout.c */
int kairo_rt_fmt_write_shortest_(unsigned char *out, size_t cap, db_dec d, unsigned char conv, int p);
int kairo_rt_fmt_format_float_(unsigned char *out, size_t cap, const fclass *f, uint64_t bits, int fast,
                               int max_digits, int prec, unsigned char conv);

#endif
