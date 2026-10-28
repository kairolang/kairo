/* --- The Kairo Project ------------------ Lib/rt/fmt_dragonbox32.c --- */
/*
 *   Dragonbox to_decimal for binary32: shortest round-trip digits.
 *
 *   The Dragonbox port and its cache tables derive from jk-jeon/dragonbox,
 *   Copyright 2020-2025 Junekey Jeon, used under the Boost Software License
 *   1.0 (alternatively Apache-2.0 WITH LLVM-exception).
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt_impl.h"

/* --- binary32 -------------------------------------------------------- */

/* Per-format constants, each derived from the paper's formulas and checked
 * exactly offline:
 *   kappa       floor(log10(2^(32 - 23 - 2))) - 1 = 1            big divisor 100
 *   min_k/max_k the cache range: 78 entries for k in [-31, 46]
 *   the shorter-interval endpoints are integers for e in [2, 3] (left) and
 *   [0, 3] (right); the shorter-interval tie window is e == -35. */
#define DB32_MIN_K   (-31)
#define DB32_TIE_LO  (-35)
#define DB32_TIE_HI  (-35)

static const uint64_t db32_cache[78] = {
    UINT64_C(0x81ceb32c4b43fcf5), UINT64_C(0xa2425ff75e14fc32),
    UINT64_C(0xcad2f7f5359a3b3f), UINT64_C(0xfd87b5f28300ca0e),
    UINT64_C(0x9e74d1b791e07e49), UINT64_C(0xc612062576589ddb),
    UINT64_C(0xf79687aed3eec552), UINT64_C(0x9abe14cd44753b53),
    UINT64_C(0xc16d9a0095928a28), UINT64_C(0xf1c90080baf72cb2),
    UINT64_C(0x971da05074da7bef), UINT64_C(0xbce5086492111aeb),
    UINT64_C(0xec1e4a7db69561a6), UINT64_C(0x9392ee8e921d5d08),
    UINT64_C(0xb877aa3236a4b44a), UINT64_C(0xe69594bec44de15c),
    UINT64_C(0x901d7cf73ab0acda), UINT64_C(0xb424dc35095cd810),
    UINT64_C(0xe12e13424bb40e14), UINT64_C(0x8cbccc096f5088cc),
    UINT64_C(0xafebff0bcb24aaff), UINT64_C(0xdbe6fecebdedd5bf),
    UINT64_C(0x89705f4136b4a598), UINT64_C(0xabcc77118461cefd),
    UINT64_C(0xd6bf94d5e57a42bd), UINT64_C(0x8637bd05af6c69b6),
    UINT64_C(0xa7c5ac471b478424), UINT64_C(0xd1b71758e219652c),
    UINT64_C(0x83126e978d4fdf3c), UINT64_C(0xa3d70a3d70a3d70b),
    UINT64_C(0xcccccccccccccccd), UINT64_C(0x8000000000000000),
    UINT64_C(0xa000000000000000), UINT64_C(0xc800000000000000),
    UINT64_C(0xfa00000000000000), UINT64_C(0x9c40000000000000),
    UINT64_C(0xc350000000000000), UINT64_C(0xf424000000000000),
    UINT64_C(0x9896800000000000), UINT64_C(0xbebc200000000000),
    UINT64_C(0xee6b280000000000), UINT64_C(0x9502f90000000000),
    UINT64_C(0xba43b74000000000), UINT64_C(0xe8d4a51000000000),
    UINT64_C(0x9184e72a00000000), UINT64_C(0xb5e620f480000000),
    UINT64_C(0xe35fa931a0000000), UINT64_C(0x8e1bc9bf04000000),
    UINT64_C(0xb1a2bc2ec5000000), UINT64_C(0xde0b6b3a76400000),
    UINT64_C(0x8ac7230489e80000), UINT64_C(0xad78ebc5ac620000),
    UINT64_C(0xd8d726b7177a8000), UINT64_C(0x878678326eac9000),
    UINT64_C(0xa968163f0a57b400), UINT64_C(0xd3c21bcecceda100),
    UINT64_C(0x84595161401484a0), UINT64_C(0xa56fa5b99019a5c8),
    UINT64_C(0xcecb8f27f4200f3a), UINT64_C(0x813f3978f8940985),
    UINT64_C(0xa18f07d736b90be6), UINT64_C(0xc9f2c9cd04674edf),
    UINT64_C(0xfc6f7c4045812297), UINT64_C(0x9dc5ada82b70b59e),
    UINT64_C(0xc5371912364ce306), UINT64_C(0xf684df56c3e01bc7),
    UINT64_C(0x9a130b963a6c115d), UINT64_C(0xc097ce7bc90715b4),
    UINT64_C(0xf0bdc21abb48db21), UINT64_C(0x96769950b50d88f5),
    UINT64_C(0xbc143fa4e250eb32), UINT64_C(0xeb194f8e1ae525fe),
    UINT64_C(0x92efd1b8d0cf37bf), UINT64_C(0xb7abc627050305ae),
    UINT64_C(0xe596b7b0c643c71a), UINT64_C(0x8f7e32ce7bea5c70),
    UINT64_C(0xb35dbf821ae4f38c), UINT64_C(0xe0352f62a19e306f),
};

static inline void db32_remove_trailing_zeros(uint32_t *sig, int *exp) {
    /* Branchless divisibility search (r/pigeon768, r/TheoreticalDumbass):
     * n * inv(10^j) mod 2^32 rotated right by j is < 2^32 / 10^j iff 10^j | n,
     * and is then n / 10^j. */
    uint32_t n = *sig, r;
    int b, s;
    r = rotr32(n * UINT32_C(184254097), 4);  b = r < UINT32_C(429497);    s = b;         if (b) n = r;
    r = rotr32(n * UINT32_C(42949673), 2);   b = r < UINT32_C(42949673);  s = s * 2 + b; if (b) n = r;
    r = rotr32(n * UINT32_C(1288490189), 1); b = r < UINT32_C(429496730); s = s * 2 + b; if (b) n = r;
    *sig = n;
    *exp += s;
}

/* Nonzero finite only. */
db_dec kairo_rt_fmt_db32_to_decimal_(uint32_t bits) {
    uint32_t two_fc = (bits & UINT32_C(0x007FFFFF)) << 1;
    int      ebits  = (int)((bits >> 23) & 0xFF);
    int      even   = (bits & 1) == 0;   /* nearest-to-even reading: both endpoints included iff even */
    int      e;
    db_dec   out;

    if (ebits != 0) {
        e = ebits - 127 - 23;

        /* Shorter interval case; proceed like Schubfach. The interval is
         * closed: f_c = 2^23 is even. (ebits == 1 with two_fc == 0 is really
         * a regular interval; the paper shows the answer is the same.) */
        if (two_fc == 0) {
            int      minus_k = floor_log10_pow2_minus_log10_4_3(e);
            int      beta    = e + floor_log2_pow10(-minus_k);
            uint64_t cache   = db32_cache[-minus_k - DB32_MIN_K];
            uint32_t xi      = (uint32_t)((cache - (cache >> (23 + 2))) >> (64 - 23 - 1 - beta));
            uint32_t zi      = (uint32_t)((cache + (cache >> (23 + 1))) >> (64 - 23 - 1 - beta));
            uint32_t sig;

            /* The left endpoint is an integer only for e in [2, 3]; otherwise
             * take the ceiling. The right endpoint is included, so zi stays. */
            if (!(e >= 2 && e <= 3)) ++xi;

            /* Try the bigger divisor. zi / 10; zi < 2^27 so this magic is exact. */
            sig = (uint32_t)(((uint64_t)zi * UINT32_C(429496730)) >> 32);
            if (sig * 10 >= xi) {
                out.sig = sig;
                out.exp = minus_k + 1;
                { uint32_t s32 = sig; db32_remove_trailing_zeros(&s32, &out.exp); out.sig = s32; }
                return out;
            }

            /* Otherwise the round-up of y. */
            sig = ((uint32_t)(cache >> (64 - 23 - 2 - beta)) + 1) / 2;

            /* When a tie occurs, choose the even one. */
            if ((sig & 1) && e >= DB32_TIE_LO && e <= DB32_TIE_HI) {
                --sig;
            } else if (sig < xi) {
                ++sig;
            }
            out.sig = sig;
            out.exp = minus_k;
            return out;
        }

        two_fc |= UINT32_C(1) << 24;
    } else {
        e = -126 - 23;
    }

    {
        /* Step 1: Schubfach multiplier calculation. kappa = 1. */
        int      minus_k = floor_log10_pow2(e) - 1;
        uint64_t cache   = db32_cache[-minus_k - DB32_MIN_K];
        int      beta    = e + floor_log2_pow10(-minus_k);
        uint32_t deltai  = (uint32_t)(cache >> (64 - 1 - beta));    /* 10 <= deltai < 100 */

        /* z = (2f_c + 1) * 2^beta * cache: upper 64 of the 96-bit product. The
         * integer check is wrong for 29711844 * 2^-82 and * 2^-81 alone, and
         * since 29711844 is even the branch that would use it is never taken. */
        uint64_t zr    = umul128_hi((uint64_t)((two_fc | 1) << beta) << 32, cache);
        uint32_t zi    = (uint32_t)(zr >> 32);
        int      z_int = (uint32_t)zr == 0;

        /* Step 2: try the larger divisor; remove trailing zeros if it works.
         * zi / 100, zi < 2^24 * 100. */
        uint32_t sig = (uint32_t)(((uint64_t)zi * UINT32_C(1374389535)) >> 37);
        uint32_t r   = zi - 100 * sig;

        do {
            if (r < deltai) {
                /* Exclude the right endpoint if necessary. */
                if ((r | (uint32_t)!z_int | (uint32_t)even) == 0) {
                    --sig;
                    r = 100;
                    break;
                }
            } else if (r > deltai) {
                break;
            } else {
                /* r == deltai: compare fractional parts through the parity of
                 * x = (2f_c - 1) * 2^beta * cache, low 64 of the 96-bit product. */
                uint64_t xr    = (uint64_t)(two_fc - 1) * cache;
                int      x_par = (int)((xr >> (64 - beta)) & 1);
                int      x_int = (uint32_t)(xr >> (32 - beta)) == 0;
                if (!(x_par | (x_int & even))) break;
            }
            out.sig = sig;
            out.exp = minus_k + 1 + 1;
            { uint32_t s32 = sig; db32_remove_trailing_zeros(&s32, &out.exp); out.sig = s32; }
            return out;
        } while (0);

        /* Step 3: the significand with the smaller divisor. */
        sig *= 10;
        {
            /* delta = 10^(kappa + e log10 2 - floor(e log10 2)), so dist <= r. */
            uint32_t dist           = r - deltai / 2 + 5;
            int      approx_y_par   = ((dist ^ 5) & 1) != 0;
            uint32_t prod           = dist * UINT32_C(6554);          /* dist <= 100 */
            int      divisible      = (prod & 0xFFFF) < UINT32_C(6554);
            dist = prod >> 16;                                         /* dist / 10 */
            sig += dist;

            if (divisible) {
                /* y_i is z_i - epsilon_i or one less; the parity decides which,
                 * and an integral y under the tie rule rounds to even. */
                uint64_t yr    = (uint64_t)two_fc * cache;
                int      y_par = (int)((yr >> (64 - beta)) & 1);
                int      y_int = (uint32_t)(yr >> (32 - beta)) == 0;
                if (y_par != approx_y_par) {
                    --sig;
                } else if ((sig & 1) & y_int) {
                    --sig;
                }
            }
        }
        out.sig = sig;
        out.exp = minus_k + 1;
        return out;
    }
}
