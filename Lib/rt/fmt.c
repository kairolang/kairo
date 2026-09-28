/* --- The Kairo Project ------------------------------ Lib/rt/fmt.c --- */
/*
 *   Float text for every Kairo float format, and the heap fmt.k draws on.
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
 *                 it is this file's own.
 *
 *     exact       everything else: shortest for f16/bf16/f8/f80/f128, and
 *                 every fixed-precision request for every format. Bignum
 *                 free-format (Burger & Dybvig) with Dragonbox's tie rule,
 *                 long division for fixed precision. Slow by Dragonbox's
 *                 standard, exact by any.
 *
 *   The Dragonbox port and its cache tables derive from jk-jeon/dragonbox,
 *   Copyright 2020-2025 Junekey Jeon, used under the Boost Software License
 *   1.0 (alternatively Apache-2.0 WITH LLVM-exception).
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(((-1) >> 1) == -1, "the log formulas below need an arithmetic right shift");

unsigned char *kairo_rt_fmt_alloc(size_t n)                     { return (unsigned char *)malloc(n); }
unsigned char *kairo_rt_fmt_realloc(unsigned char *p, size_t n) { return (unsigned char *)realloc(p, n); }
void           kairo_rt_fmt_free(unsigned char *p)              { free(p); }

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
/*  Dragonbox                                                             */
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
static db_dec db32_to_decimal(uint32_t bits) {
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

/* --- binary64 -------------------------------------------------------- */

/*   kappa       floor(log10(2^(64 - 52 - 2))) - 1 = 2            big divisor 1000
 *   min_k/max_k the cache range: 619 entries for k in [-292, 326]
 *   endpoints integral for e in [2, 3] (left) and [0, 3] (right); tie window
 *   e == -77. */
#define DB64_MIN_K   (-292)
#define DB64_TIE_LO  (-77)
#define DB64_TIE_HI  (-77)

static const u128 db64_cache[619] = {
    { UINT64_C(0xff77b1fcbebcdc4f), UINT64_C(0x25e8e89c13bb0f7b) },
    { UINT64_C(0x9faacf3df73609b1), UINT64_C(0x77b191618c54e9ad) },
    { UINT64_C(0xc795830d75038c1d), UINT64_C(0xd59df5b9ef6a2418) },
    { UINT64_C(0xf97ae3d0d2446f25), UINT64_C(0x4b0573286b44ad1e) },
    { UINT64_C(0x9becce62836ac577), UINT64_C(0x4ee367f9430aec33) },
    { UINT64_C(0xc2e801fb244576d5), UINT64_C(0x229c41f793cda740) },
    { UINT64_C(0xf3a20279ed56d48a), UINT64_C(0x6b43527578c11110) },
    { UINT64_C(0x9845418c345644d6), UINT64_C(0x830a13896b78aaaa) },
    { UINT64_C(0xbe5691ef416bd60c), UINT64_C(0x23cc986bc656d554) },
    { UINT64_C(0xedec366b11c6cb8f), UINT64_C(0x2cbfbe86b7ec8aa9) },
    { UINT64_C(0x94b3a202eb1c3f39), UINT64_C(0x7bf7d71432f3d6aa) },
    { UINT64_C(0xb9e08a83a5e34f07), UINT64_C(0xdaf5ccd93fb0cc54) },
    { UINT64_C(0xe858ad248f5c22c9), UINT64_C(0xd1b3400f8f9cff69) },
    { UINT64_C(0x91376c36d99995be), UINT64_C(0x23100809b9c21fa2) },
    { UINT64_C(0xb58547448ffffb2d), UINT64_C(0xabd40a0c2832a78b) },
    { UINT64_C(0xe2e69915b3fff9f9), UINT64_C(0x16c90c8f323f516d) },
    { UINT64_C(0x8dd01fad907ffc3b), UINT64_C(0xae3da7d97f6792e4) },
    { UINT64_C(0xb1442798f49ffb4a), UINT64_C(0x99cd11cfdf41779d) },
    { UINT64_C(0xdd95317f31c7fa1d), UINT64_C(0x40405643d711d584) },
    { UINT64_C(0x8a7d3eef7f1cfc52), UINT64_C(0x482835ea666b2573) },
    { UINT64_C(0xad1c8eab5ee43b66), UINT64_C(0xda3243650005eed0) },
    { UINT64_C(0xd863b256369d4a40), UINT64_C(0x90bed43e40076a83) },
    { UINT64_C(0x873e4f75e2224e68), UINT64_C(0x5a7744a6e804a292) },
    { UINT64_C(0xa90de3535aaae202), UINT64_C(0x711515d0a205cb37) },
    { UINT64_C(0xd3515c2831559a83), UINT64_C(0x0d5a5b44ca873e04) },
    { UINT64_C(0x8412d9991ed58091), UINT64_C(0xe858790afe9486c3) },
    { UINT64_C(0xa5178fff668ae0b6), UINT64_C(0x626e974dbe39a873) },
    { UINT64_C(0xce5d73ff402d98e3), UINT64_C(0xfb0a3d212dc81290) },
    { UINT64_C(0x80fa687f881c7f8e), UINT64_C(0x7ce66634bc9d0b9a) },
    { UINT64_C(0xa139029f6a239f72), UINT64_C(0x1c1fffc1ebc44e81) },
    { UINT64_C(0xc987434744ac874e), UINT64_C(0xa327ffb266b56221) },
    { UINT64_C(0xfbe9141915d7a922), UINT64_C(0x4bf1ff9f0062baa9) },
    { UINT64_C(0x9d71ac8fada6c9b5), UINT64_C(0x6f773fc3603db4aa) },
    { UINT64_C(0xc4ce17b399107c22), UINT64_C(0xcb550fb4384d21d4) },
    { UINT64_C(0xf6019da07f549b2b), UINT64_C(0x7e2a53a146606a49) },
    { UINT64_C(0x99c102844f94e0fb), UINT64_C(0x2eda7444cbfc426e) },
    { UINT64_C(0xc0314325637a1939), UINT64_C(0xfa911155fefb5309) },
    { UINT64_C(0xf03d93eebc589f88), UINT64_C(0x793555ab7eba27cb) },
    { UINT64_C(0x96267c7535b763b5), UINT64_C(0x4bc1558b2f3458df) },
    { UINT64_C(0xbbb01b9283253ca2), UINT64_C(0x9eb1aaedfb016f17) },
    { UINT64_C(0xea9c227723ee8bcb), UINT64_C(0x465e15a979c1cadd) },
    { UINT64_C(0x92a1958a7675175f), UINT64_C(0x0bfacd89ec191eca) },
    { UINT64_C(0xb749faed14125d36), UINT64_C(0xcef980ec671f667c) },
    { UINT64_C(0xe51c79a85916f484), UINT64_C(0x82b7e12780e7401b) },
    { UINT64_C(0x8f31cc0937ae58d2), UINT64_C(0xd1b2ecb8b0908811) },
    { UINT64_C(0xb2fe3f0b8599ef07), UINT64_C(0x861fa7e6dcb4aa16) },
    { UINT64_C(0xdfbdcece67006ac9), UINT64_C(0x67a791e093e1d49b) },
    { UINT64_C(0x8bd6a141006042bd), UINT64_C(0xe0c8bb2c5c6d24e1) },
    { UINT64_C(0xaecc49914078536d), UINT64_C(0x58fae9f773886e19) },
    { UINT64_C(0xda7f5bf590966848), UINT64_C(0xaf39a475506a899f) },
    { UINT64_C(0x888f99797a5e012d), UINT64_C(0x6d8406c952429604) },
    { UINT64_C(0xaab37fd7d8f58178), UINT64_C(0xc8e5087ba6d33b84) },
    { UINT64_C(0xd5605fcdcf32e1d6), UINT64_C(0xfb1e4a9a90880a65) },
    { UINT64_C(0x855c3be0a17fcd26), UINT64_C(0x5cf2eea09a550680) },
    { UINT64_C(0xa6b34ad8c9dfc06f), UINT64_C(0xf42faa48c0ea481f) },
    { UINT64_C(0xd0601d8efc57b08b), UINT64_C(0xf13b94daf124da27) },
    { UINT64_C(0x823c12795db6ce57), UINT64_C(0x76c53d08d6b70859) },
    { UINT64_C(0xa2cb1717b52481ed), UINT64_C(0x54768c4b0c64ca6f) },
    { UINT64_C(0xcb7ddcdda26da268), UINT64_C(0xa9942f5dcf7dfd0a) },
    { UINT64_C(0xfe5d54150b090b02), UINT64_C(0xd3f93b35435d7c4d) },
    { UINT64_C(0x9efa548d26e5a6e1), UINT64_C(0xc47bc5014a1a6db0) },
    { UINT64_C(0xc6b8e9b0709f109a), UINT64_C(0x359ab6419ca1091c) },
    { UINT64_C(0xf867241c8cc6d4c0), UINT64_C(0xc30163d203c94b63) },
    { UINT64_C(0x9b407691d7fc44f8), UINT64_C(0x79e0de63425dcf1e) },
    { UINT64_C(0xc21094364dfb5636), UINT64_C(0x985915fc12f542e5) },
    { UINT64_C(0xf294b943e17a2bc4), UINT64_C(0x3e6f5b7b17b2939e) },
    { UINT64_C(0x979cf3ca6cec5b5a), UINT64_C(0xa705992ceecf9c43) },
    { UINT64_C(0xbd8430bd08277231), UINT64_C(0x50c6ff782a838354) },
    { UINT64_C(0xece53cec4a314ebd), UINT64_C(0xa4f8bf5635246429) },
    { UINT64_C(0x940f4613ae5ed136), UINT64_C(0x871b7795e136be9a) },
    { UINT64_C(0xb913179899f68584), UINT64_C(0x28e2557b59846e40) },
    { UINT64_C(0xe757dd7ec07426e5), UINT64_C(0x331aeada2fe589d0) },
    { UINT64_C(0x9096ea6f3848984f), UINT64_C(0x3ff0d2c85def7622) },
    { UINT64_C(0xb4bca50b065abe63), UINT64_C(0x0fed077a756b53aa) },
    { UINT64_C(0xe1ebce4dc7f16dfb), UINT64_C(0xd3e8495912c62895) },
    { UINT64_C(0x8d3360f09cf6e4bd), UINT64_C(0x64712dd7abbbd95d) },
    { UINT64_C(0xb080392cc4349dec), UINT64_C(0xbd8d794d96aacfb4) },
    { UINT64_C(0xdca04777f541c567), UINT64_C(0xecf0d7a0fc5583a1) },
    { UINT64_C(0x89e42caaf9491b60), UINT64_C(0xf41686c49db57245) },
    { UINT64_C(0xac5d37d5b79b6239), UINT64_C(0x311c2875c522ced6) },
    { UINT64_C(0xd77485cb25823ac7), UINT64_C(0x7d633293366b828c) },
    { UINT64_C(0x86a8d39ef77164bc), UINT64_C(0xae5dff9c02033198) },
    { UINT64_C(0xa8530886b54dbdeb), UINT64_C(0xd9f57f830283fdfd) },
    { UINT64_C(0xd267caa862a12d66), UINT64_C(0xd072df63c324fd7c) },
    { UINT64_C(0x8380dea93da4bc60), UINT64_C(0x4247cb9e59f71e6e) },
    { UINT64_C(0xa46116538d0deb78), UINT64_C(0x52d9be85f074e609) },
    { UINT64_C(0xcd795be870516656), UINT64_C(0x67902e276c921f8c) },
    { UINT64_C(0x806bd9714632dff6), UINT64_C(0x00ba1cd8a3db53b7) },
    { UINT64_C(0xa086cfcd97bf97f3), UINT64_C(0x80e8a40eccd228a5) },
    { UINT64_C(0xc8a883c0fdaf7df0), UINT64_C(0x6122cd128006b2ce) },
    { UINT64_C(0xfad2a4b13d1b5d6c), UINT64_C(0x796b805720085f82) },
    { UINT64_C(0x9cc3a6eec6311a63), UINT64_C(0xcbe3303674053bb1) },
    { UINT64_C(0xc3f490aa77bd60fc), UINT64_C(0xbedbfc4411068a9d) },
    { UINT64_C(0xf4f1b4d515acb93b), UINT64_C(0xee92fb5515482d45) },
    { UINT64_C(0x991711052d8bf3c5), UINT64_C(0x751bdd152d4d1c4b) },
    { UINT64_C(0xbf5cd54678eef0b6), UINT64_C(0xd262d45a78a0635e) },
    { UINT64_C(0xef340a98172aace4), UINT64_C(0x86fb897116c87c35) },
    { UINT64_C(0x9580869f0e7aac0e), UINT64_C(0xd45d35e6ae3d4da1) },
    { UINT64_C(0xbae0a846d2195712), UINT64_C(0x8974836059cca10a) },
    { UINT64_C(0xe998d258869facd7), UINT64_C(0x2bd1a438703fc94c) },
    { UINT64_C(0x91ff83775423cc06), UINT64_C(0x7b6306a34627ddd0) },
    { UINT64_C(0xb67f6455292cbf08), UINT64_C(0x1a3bc84c17b1d543) },
    { UINT64_C(0xe41f3d6a7377eeca), UINT64_C(0x20caba5f1d9e4a94) },
    { UINT64_C(0x8e938662882af53e), UINT64_C(0x547eb47b7282ee9d) },
    { UINT64_C(0xb23867fb2a35b28d), UINT64_C(0xe99e619a4f23aa44) },
    { UINT64_C(0xdec681f9f4c31f31), UINT64_C(0x6405fa00e2ec94d5) },
    { UINT64_C(0x8b3c113c38f9f37e), UINT64_C(0xde83bc408dd3dd05) },
    { UINT64_C(0xae0b158b4738705e), UINT64_C(0x9624ab50b148d446) },
    { UINT64_C(0xd98ddaee19068c76), UINT64_C(0x3badd624dd9b0958) },
    { UINT64_C(0x87f8a8d4cfa417c9), UINT64_C(0xe54ca5d70a80e5d7) },
    { UINT64_C(0xa9f6d30a038d1dbc), UINT64_C(0x5e9fcf4ccd211f4d) },
    { UINT64_C(0xd47487cc8470652b), UINT64_C(0x7647c32000696720) },
    { UINT64_C(0x84c8d4dfd2c63f3b), UINT64_C(0x29ecd9f40041e074) },
    { UINT64_C(0xa5fb0a17c777cf09), UINT64_C(0xf468107100525891) },
    { UINT64_C(0xcf79cc9db955c2cc), UINT64_C(0x7182148d4066eeb5) },
    { UINT64_C(0x81ac1fe293d599bf), UINT64_C(0xc6f14cd848405531) },
    { UINT64_C(0xa21727db38cb002f), UINT64_C(0xb8ada00e5a506a7d) },
    { UINT64_C(0xca9cf1d206fdc03b), UINT64_C(0xa6d90811f0e4851d) },
    { UINT64_C(0xfd442e4688bd304a), UINT64_C(0x908f4a166d1da664) },
    { UINT64_C(0x9e4a9cec15763e2e), UINT64_C(0x9a598e4e043287ff) },
    { UINT64_C(0xc5dd44271ad3cdba), UINT64_C(0x40eff1e1853f29fe) },
    { UINT64_C(0xf7549530e188c128), UINT64_C(0xd12bee59e68ef47d) },
    { UINT64_C(0x9a94dd3e8cf578b9), UINT64_C(0x82bb74f8301958cf) },
    { UINT64_C(0xc13a148e3032d6e7), UINT64_C(0xe36a52363c1faf02) },
    { UINT64_C(0xf18899b1bc3f8ca1), UINT64_C(0xdc44e6c3cb279ac2) },
    { UINT64_C(0x96f5600f15a7b7e5), UINT64_C(0x29ab103a5ef8c0ba) },
    { UINT64_C(0xbcb2b812db11a5de), UINT64_C(0x7415d448f6b6f0e8) },
    { UINT64_C(0xebdf661791d60f56), UINT64_C(0x111b495b3464ad22) },
    { UINT64_C(0x936b9fcebb25c995), UINT64_C(0xcab10dd900beec35) },
    { UINT64_C(0xb84687c269ef3bfb), UINT64_C(0x3d5d514f40eea743) },
    { UINT64_C(0xe65829b3046b0afa), UINT64_C(0x0cb4a5a3112a5113) },
    { UINT64_C(0x8ff71a0fe2c2e6dc), UINT64_C(0x47f0e785eaba72ac) },
    { UINT64_C(0xb3f4e093db73a093), UINT64_C(0x59ed216765690f57) },
    { UINT64_C(0xe0f218b8d25088b8), UINT64_C(0x306869c13ec3532d) },
    { UINT64_C(0x8c974f7383725573), UINT64_C(0x1e414218c73a13fc) },
    { UINT64_C(0xafbd2350644eeacf), UINT64_C(0xe5d1929ef90898fb) },
    { UINT64_C(0xdbac6c247d62a583), UINT64_C(0xdf45f746b74abf3a) },
    { UINT64_C(0x894bc396ce5da772), UINT64_C(0x6b8bba8c328eb784) },
    { UINT64_C(0xab9eb47c81f5114f), UINT64_C(0x066ea92f3f326565) },
    { UINT64_C(0xd686619ba27255a2), UINT64_C(0xc80a537b0efefebe) },
    { UINT64_C(0x8613fd0145877585), UINT64_C(0xbd06742ce95f5f37) },
    { UINT64_C(0xa798fc4196e952e7), UINT64_C(0x2c48113823b73705) },
    { UINT64_C(0xd17f3b51fca3a7a0), UINT64_C(0xf75a15862ca504c6) },
    { UINT64_C(0x82ef85133de648c4), UINT64_C(0x9a984d73dbe722fc) },
    { UINT64_C(0xa3ab66580d5fdaf5), UINT64_C(0xc13e60d0d2e0ebbb) },
    { UINT64_C(0xcc963fee10b7d1b3), UINT64_C(0x318df905079926a9) },
    { UINT64_C(0xffbbcfe994e5c61f), UINT64_C(0xfdf17746497f7053) },
    { UINT64_C(0x9fd561f1fd0f9bd3), UINT64_C(0xfeb6ea8bedefa634) },
    { UINT64_C(0xc7caba6e7c5382c8), UINT64_C(0xfe64a52ee96b8fc1) },
    { UINT64_C(0xf9bd690a1b68637b), UINT64_C(0x3dfdce7aa3c673b1) },
    { UINT64_C(0x9c1661a651213e2d), UINT64_C(0x06bea10ca65c084f) },
    { UINT64_C(0xc31bfa0fe5698db8), UINT64_C(0x486e494fcff30a63) },
    { UINT64_C(0xf3e2f893dec3f126), UINT64_C(0x5a89dba3c3efccfb) },
    { UINT64_C(0x986ddb5c6b3a76b7), UINT64_C(0xf89629465a75e01d) },
    { UINT64_C(0xbe89523386091465), UINT64_C(0xf6bbb397f1135824) },
    { UINT64_C(0xee2ba6c0678b597f), UINT64_C(0x746aa07ded582e2d) },
    { UINT64_C(0x94db483840b717ef), UINT64_C(0xa8c2a44eb4571cdd) },
    { UINT64_C(0xba121a4650e4ddeb), UINT64_C(0x92f34d62616ce414) },
    { UINT64_C(0xe896a0d7e51e1566), UINT64_C(0x77b020baf9c81d18) },
    { UINT64_C(0x915e2486ef32cd60), UINT64_C(0x0ace1474dc1d122f) },
    { UINT64_C(0xb5b5ada8aaff80b8), UINT64_C(0x0d819992132456bb) },
    { UINT64_C(0xe3231912d5bf60e6), UINT64_C(0x10e1fff697ed6c6a) },
    { UINT64_C(0x8df5efabc5979c8f), UINT64_C(0xca8d3ffa1ef463c2) },
    { UINT64_C(0xb1736b96b6fd83b3), UINT64_C(0xbd308ff8a6b17cb3) },
    { UINT64_C(0xddd0467c64bce4a0), UINT64_C(0xac7cb3f6d05ddbdf) },
    { UINT64_C(0x8aa22c0dbef60ee4), UINT64_C(0x6bcdf07a423aa96c) },
    { UINT64_C(0xad4ab7112eb3929d), UINT64_C(0x86c16c98d2c953c7) },
    { UINT64_C(0xd89d64d57a607744), UINT64_C(0xe871c7bf077ba8b8) },
    { UINT64_C(0x87625f056c7c4a8b), UINT64_C(0x11471cd764ad4973) },
    { UINT64_C(0xa93af6c6c79b5d2d), UINT64_C(0xd598e40d3dd89bd0) },
    { UINT64_C(0xd389b47879823479), UINT64_C(0x4aff1d108d4ec2c4) },
    { UINT64_C(0x843610cb4bf160cb), UINT64_C(0xcedf722a585139bb) },
    { UINT64_C(0xa54394fe1eedb8fe), UINT64_C(0xc2974eb4ee658829) },
    { UINT64_C(0xce947a3da6a9273e), UINT64_C(0x733d226229feea33) },
    { UINT64_C(0x811ccc668829b887), UINT64_C(0x0806357d5a3f5260) },
    { UINT64_C(0xa163ff802a3426a8), UINT64_C(0xca07c2dcb0cf26f8) },
    { UINT64_C(0xc9bcff6034c13052), UINT64_C(0xfc89b393dd02f0b6) },
    { UINT64_C(0xfc2c3f3841f17c67), UINT64_C(0xbbac2078d443ace3) },
    { UINT64_C(0x9d9ba7832936edc0), UINT64_C(0xd54b944b84aa4c0e) },
    { UINT64_C(0xc5029163f384a931), UINT64_C(0x0a9e795e65d4df12) },
    { UINT64_C(0xf64335bcf065d37d), UINT64_C(0x4d4617b5ff4a16d6) },
    { UINT64_C(0x99ea0196163fa42e), UINT64_C(0x504bced1bf8e4e46) },
    { UINT64_C(0xc06481fb9bcf8d39), UINT64_C(0xe45ec2862f71e1d7) },
    { UINT64_C(0xf07da27a82c37088), UINT64_C(0x5d767327bb4e5a4d) },
    { UINT64_C(0x964e858c91ba2655), UINT64_C(0x3a6a07f8d510f870) },
    { UINT64_C(0xbbe226efb628afea), UINT64_C(0x890489f70a55368c) },
    { UINT64_C(0xeadab0aba3b2dbe5), UINT64_C(0x2b45ac74ccea842f) },
    { UINT64_C(0x92c8ae6b464fc96f), UINT64_C(0x3b0b8bc90012929e) },
    { UINT64_C(0xb77ada0617e3bbcb), UINT64_C(0x09ce6ebb40173745) },
    { UINT64_C(0xe55990879ddcaabd), UINT64_C(0xcc420a6a101d0516) },
    { UINT64_C(0x8f57fa54c2a9eab6), UINT64_C(0x9fa946824a12232e) },
    { UINT64_C(0xb32df8e9f3546564), UINT64_C(0x47939822dc96abfa) },
    { UINT64_C(0xdff9772470297ebd), UINT64_C(0x59787e2b93bc56f8) },
    { UINT64_C(0x8bfbea76c619ef36), UINT64_C(0x57eb4edb3c55b65b) },
    { UINT64_C(0xaefae51477a06b03), UINT64_C(0xede622920b6b23f2) },
    { UINT64_C(0xdab99e59958885c4), UINT64_C(0xe95fab368e45ecee) },
    { UINT64_C(0x88b402f7fd75539b), UINT64_C(0x11dbcb0218ebb415) },
    { UINT64_C(0xaae103b5fcd2a881), UINT64_C(0xd652bdc29f26a11a) },
    { UINT64_C(0xd59944a37c0752a2), UINT64_C(0x4be76d3346f04960) },
    { UINT64_C(0x857fcae62d8493a5), UINT64_C(0x6f70a4400c562ddc) },
    { UINT64_C(0xa6dfbd9fb8e5b88e), UINT64_C(0xcb4ccd500f6bb953) },
    { UINT64_C(0xd097ad07a71f26b2), UINT64_C(0x7e2000a41346a7a8) },
    { UINT64_C(0x825ecc24c873782f), UINT64_C(0x8ed400668c0c28c9) },
    { UINT64_C(0xa2f67f2dfa90563b), UINT64_C(0x728900802f0f32fb) },
    { UINT64_C(0xcbb41ef979346bca), UINT64_C(0x4f2b40a03ad2ffba) },
    { UINT64_C(0xfea126b7d78186bc), UINT64_C(0xe2f610c84987bfa9) },
    { UINT64_C(0x9f24b832e6b0f436), UINT64_C(0x0dd9ca7d2df4d7ca) },
    { UINT64_C(0xc6ede63fa05d3143), UINT64_C(0x91503d1c79720dbc) },
    { UINT64_C(0xf8a95fcf88747d94), UINT64_C(0x75a44c6397ce912b) },
    { UINT64_C(0x9b69dbe1b548ce7c), UINT64_C(0xc986afbe3ee11abb) },
    { UINT64_C(0xc24452da229b021b), UINT64_C(0xfbe85badce996169) },
    { UINT64_C(0xf2d56790ab41c2a2), UINT64_C(0xfae27299423fb9c4) },
    { UINT64_C(0x97c560ba6b0919a5), UINT64_C(0xdccd879fc967d41b) },
    { UINT64_C(0xbdb6b8e905cb600f), UINT64_C(0x5400e987bbc1c921) },
    { UINT64_C(0xed246723473e3813), UINT64_C(0x290123e9aab23b69) },
    { UINT64_C(0x9436c0760c86e30b), UINT64_C(0xf9a0b6720aaf6522) },
    { UINT64_C(0xb94470938fa89bce), UINT64_C(0xf808e40e8d5b3e6a) },
    { UINT64_C(0xe7958cb87392c2c2), UINT64_C(0xb60b1d1230b20e05) },
    { UINT64_C(0x90bd77f3483bb9b9), UINT64_C(0xb1c6f22b5e6f48c3) },
    { UINT64_C(0xb4ecd5f01a4aa828), UINT64_C(0x1e38aeb6360b1af4) },
    { UINT64_C(0xe2280b6c20dd5232), UINT64_C(0x25c6da63c38de1b1) },
    { UINT64_C(0x8d590723948a535f), UINT64_C(0x579c487e5a38ad0f) },
    { UINT64_C(0xb0af48ec79ace837), UINT64_C(0x2d835a9df0c6d852) },
    { UINT64_C(0xdcdb1b2798182244), UINT64_C(0xf8e431456cf88e66) },
    { UINT64_C(0x8a08f0f8bf0f156b), UINT64_C(0x1b8e9ecb641b5900) },
    { UINT64_C(0xac8b2d36eed2dac5), UINT64_C(0xe272467e3d222f40) },
    { UINT64_C(0xd7adf884aa879177), UINT64_C(0x5b0ed81dcc6abb10) },
    { UINT64_C(0x86ccbb52ea94baea), UINT64_C(0x98e947129fc2b4ea) },
    { UINT64_C(0xa87fea27a539e9a5), UINT64_C(0x3f2398d747b36225) },
    { UINT64_C(0xd29fe4b18e88640e), UINT64_C(0x8eec7f0d19a03aae) },
    { UINT64_C(0x83a3eeeef9153e89), UINT64_C(0x1953cf68300424ad) },
    { UINT64_C(0xa48ceaaab75a8e2b), UINT64_C(0x5fa8c3423c052dd8) },
    { UINT64_C(0xcdb02555653131b6), UINT64_C(0x3792f412cb06794e) },
    { UINT64_C(0x808e17555f3ebf11), UINT64_C(0xe2bbd88bbee40bd1) },
    { UINT64_C(0xa0b19d2ab70e6ed6), UINT64_C(0x5b6aceaeae9d0ec5) },
    { UINT64_C(0xc8de047564d20a8b), UINT64_C(0xf245825a5a445276) },
    { UINT64_C(0xfb158592be068d2e), UINT64_C(0xeed6e2f0f0d56713) },
    { UINT64_C(0x9ced737bb6c4183d), UINT64_C(0x55464dd69685606c) },
    { UINT64_C(0xc428d05aa4751e4c), UINT64_C(0xaa97e14c3c26b887) },
    { UINT64_C(0xf53304714d9265df), UINT64_C(0xd53dd99f4b3066a9) },
    { UINT64_C(0x993fe2c6d07b7fab), UINT64_C(0xe546a8038efe402a) },
    { UINT64_C(0xbf8fdb78849a5f96), UINT64_C(0xde98520472bdd034) },
    { UINT64_C(0xef73d256a5c0f77c), UINT64_C(0x963e66858f6d4441) },
    { UINT64_C(0x95a8637627989aad), UINT64_C(0xdde7001379a44aa9) },
    { UINT64_C(0xbb127c53b17ec159), UINT64_C(0x5560c018580d5d53) },
    { UINT64_C(0xe9d71b689dde71af), UINT64_C(0xaab8f01e6e10b4a7) },
    { UINT64_C(0x9226712162ab070d), UINT64_C(0xcab3961304ca70e9) },
    { UINT64_C(0xb6b00d69bb55c8d1), UINT64_C(0x3d607b97c5fd0d23) },
    { UINT64_C(0xe45c10c42a2b3b05), UINT64_C(0x8cb89a7db77c506b) },
    { UINT64_C(0x8eb98a7a9a5b04e3), UINT64_C(0x77f3608e92adb243) },
    { UINT64_C(0xb267ed1940f1c61c), UINT64_C(0x55f038b237591ed4) },
    { UINT64_C(0xdf01e85f912e37a3), UINT64_C(0x6b6c46dec52f6689) },
    { UINT64_C(0x8b61313bbabce2c6), UINT64_C(0x2323ac4b3b3da016) },
    { UINT64_C(0xae397d8aa96c1b77), UINT64_C(0xabec975e0a0d081b) },
    { UINT64_C(0xd9c7dced53c72255), UINT64_C(0x96e7bd358c904a22) },
    { UINT64_C(0x881cea14545c7575), UINT64_C(0x7e50d64177da2e55) },
    { UINT64_C(0xaa242499697392d2), UINT64_C(0xdde50bd1d5d0b9ea) },
    { UINT64_C(0xd4ad2dbfc3d07787), UINT64_C(0x955e4ec64b44e865) },
    { UINT64_C(0x84ec3c97da624ab4), UINT64_C(0xbd5af13bef0b113f) },
    { UINT64_C(0xa6274bbdd0fadd61), UINT64_C(0xecb1ad8aeacdd58f) },
    { UINT64_C(0xcfb11ead453994ba), UINT64_C(0x67de18eda5814af3) },
    { UINT64_C(0x81ceb32c4b43fcf4), UINT64_C(0x80eacf948770ced8) },
    { UINT64_C(0xa2425ff75e14fc31), UINT64_C(0xa1258379a94d028e) },
    { UINT64_C(0xcad2f7f5359a3b3e), UINT64_C(0x096ee45813a04331) },
    { UINT64_C(0xfd87b5f28300ca0d), UINT64_C(0x8bca9d6e188853fd) },
    { UINT64_C(0x9e74d1b791e07e48), UINT64_C(0x775ea264cf55347e) },
    { UINT64_C(0xc612062576589dda), UINT64_C(0x95364afe032a819e) },
    { UINT64_C(0xf79687aed3eec551), UINT64_C(0x3a83ddbd83f52205) },
    { UINT64_C(0x9abe14cd44753b52), UINT64_C(0xc4926a9672793543) },
    { UINT64_C(0xc16d9a0095928a27), UINT64_C(0x75b7053c0f178294) },
    { UINT64_C(0xf1c90080baf72cb1), UINT64_C(0x5324c68b12dd6339) },
    { UINT64_C(0x971da05074da7bee), UINT64_C(0xd3f6fc16ebca5e04) },
    { UINT64_C(0xbce5086492111aea), UINT64_C(0x88f4bb1ca6bcf585) },
    { UINT64_C(0xec1e4a7db69561a5), UINT64_C(0x2b31e9e3d06c32e6) },
    { UINT64_C(0x9392ee8e921d5d07), UINT64_C(0x3aff322e62439fd0) },
    { UINT64_C(0xb877aa3236a4b449), UINT64_C(0x09befeb9fad487c3) },
    { UINT64_C(0xe69594bec44de15b), UINT64_C(0x4c2ebe687989a9b4) },
    { UINT64_C(0x901d7cf73ab0acd9), UINT64_C(0x0f9d37014bf60a11) },
    { UINT64_C(0xb424dc35095cd80f), UINT64_C(0x538484c19ef38c95) },
    { UINT64_C(0xe12e13424bb40e13), UINT64_C(0x2865a5f206b06fba) },
    { UINT64_C(0x8cbccc096f5088cb), UINT64_C(0xf93f87b7442e45d4) },
    { UINT64_C(0xafebff0bcb24aafe), UINT64_C(0xf78f69a51539d749) },
    { UINT64_C(0xdbe6fecebdedd5be), UINT64_C(0xb573440e5a884d1c) },
    { UINT64_C(0x89705f4136b4a597), UINT64_C(0x31680a88f8953031) },
    { UINT64_C(0xabcc77118461cefc), UINT64_C(0xfdc20d2b36ba7c3e) },
    { UINT64_C(0xd6bf94d5e57a42bc), UINT64_C(0x3d32907604691b4d) },
    { UINT64_C(0x8637bd05af6c69b5), UINT64_C(0xa63f9a49c2c1b110) },
    { UINT64_C(0xa7c5ac471b478423), UINT64_C(0x0fcf80dc33721d54) },
    { UINT64_C(0xd1b71758e219652b), UINT64_C(0xd3c36113404ea4a9) },
    { UINT64_C(0x83126e978d4fdf3b), UINT64_C(0x645a1cac083126ea) },
    { UINT64_C(0xa3d70a3d70a3d70a), UINT64_C(0x3d70a3d70a3d70a4) },
    { UINT64_C(0xcccccccccccccccc), UINT64_C(0xcccccccccccccccd) },
    { UINT64_C(0x8000000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xa000000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xc800000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xfa00000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x9c40000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xc350000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xf424000000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x9896800000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xbebc200000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xee6b280000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x9502f90000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xba43b74000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xe8d4a51000000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x9184e72a00000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xb5e620f480000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xe35fa931a0000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x8e1bc9bf04000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xb1a2bc2ec5000000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xde0b6b3a76400000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x8ac7230489e80000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xad78ebc5ac620000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xd8d726b7177a8000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x878678326eac9000), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xa968163f0a57b400), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xd3c21bcecceda100), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x84595161401484a0), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xa56fa5b99019a5c8), UINT64_C(0x0000000000000000) },
    { UINT64_C(0xcecb8f27f4200f3a), UINT64_C(0x0000000000000000) },
    { UINT64_C(0x813f3978f8940984), UINT64_C(0x4000000000000000) },
    { UINT64_C(0xa18f07d736b90be5), UINT64_C(0x5000000000000000) },
    { UINT64_C(0xc9f2c9cd04674ede), UINT64_C(0xa400000000000000) },
    { UINT64_C(0xfc6f7c4045812296), UINT64_C(0x4d00000000000000) },
    { UINT64_C(0x9dc5ada82b70b59d), UINT64_C(0xf020000000000000) },
    { UINT64_C(0xc5371912364ce305), UINT64_C(0x6c28000000000000) },
    { UINT64_C(0xf684df56c3e01bc6), UINT64_C(0xc732000000000000) },
    { UINT64_C(0x9a130b963a6c115c), UINT64_C(0x3c7f400000000000) },
    { UINT64_C(0xc097ce7bc90715b3), UINT64_C(0x4b9f100000000000) },
    { UINT64_C(0xf0bdc21abb48db20), UINT64_C(0x1e86d40000000000) },
    { UINT64_C(0x96769950b50d88f4), UINT64_C(0x1314448000000000) },
    { UINT64_C(0xbc143fa4e250eb31), UINT64_C(0x17d955a000000000) },
    { UINT64_C(0xeb194f8e1ae525fd), UINT64_C(0x5dcfab0800000000) },
    { UINT64_C(0x92efd1b8d0cf37be), UINT64_C(0x5aa1cae500000000) },
    { UINT64_C(0xb7abc627050305ad), UINT64_C(0xf14a3d9e40000000) },
    { UINT64_C(0xe596b7b0c643c719), UINT64_C(0x6d9ccd05d0000000) },
    { UINT64_C(0x8f7e32ce7bea5c6f), UINT64_C(0xe4820023a2000000) },
    { UINT64_C(0xb35dbf821ae4f38b), UINT64_C(0xdda2802c8a800000) },
    { UINT64_C(0xe0352f62a19e306e), UINT64_C(0xd50b2037ad200000) },
    { UINT64_C(0x8c213d9da502de45), UINT64_C(0x4526f422cc340000) },
    { UINT64_C(0xaf298d050e4395d6), UINT64_C(0x9670b12b7f410000) },
    { UINT64_C(0xdaf3f04651d47b4c), UINT64_C(0x3c0cdd765f114000) },
    { UINT64_C(0x88d8762bf324cd0f), UINT64_C(0xa5880a69fb6ac800) },
    { UINT64_C(0xab0e93b6efee0053), UINT64_C(0x8eea0d047a457a00) },
    { UINT64_C(0xd5d238a4abe98068), UINT64_C(0x72a4904598d6d880) },
    { UINT64_C(0x85a36366eb71f041), UINT64_C(0x47a6da2b7f864750) },
    { UINT64_C(0xa70c3c40a64e6c51), UINT64_C(0x999090b65f67d924) },
    { UINT64_C(0xd0cf4b50cfe20765), UINT64_C(0xfff4b4e3f741cf6d) },
    { UINT64_C(0x82818f1281ed449f), UINT64_C(0xbff8f10e7a8921a5) },
    { UINT64_C(0xa321f2d7226895c7), UINT64_C(0xaff72d52192b6a0e) },
    { UINT64_C(0xcbea6f8ceb02bb39), UINT64_C(0x9bf4f8a69f764491) },
    { UINT64_C(0xfee50b7025c36a08), UINT64_C(0x02f236d04753d5b5) },
    { UINT64_C(0x9f4f2726179a2245), UINT64_C(0x01d762422c946591) },
    { UINT64_C(0xc722f0ef9d80aad6), UINT64_C(0x424d3ad2b7b97ef6) },
    { UINT64_C(0xf8ebad2b84e0d58b), UINT64_C(0xd2e0898765a7deb3) },
    { UINT64_C(0x9b934c3b330c8577), UINT64_C(0x63cc55f49f88eb30) },
    { UINT64_C(0xc2781f49ffcfa6d5), UINT64_C(0x3cbf6b71c76b25fc) },
    { UINT64_C(0xf316271c7fc3908a), UINT64_C(0x8bef464e3945ef7b) },
    { UINT64_C(0x97edd871cfda3a56), UINT64_C(0x97758bf0e3cbb5ad) },
    { UINT64_C(0xbde94e8e43d0c8ec), UINT64_C(0x3d52eeed1cbea318) },
    { UINT64_C(0xed63a231d4c4fb27), UINT64_C(0x4ca7aaa863ee4bde) },
    { UINT64_C(0x945e455f24fb1cf8), UINT64_C(0x8fe8caa93e74ef6b) },
    { UINT64_C(0xb975d6b6ee39e436), UINT64_C(0xb3e2fd538e122b45) },
    { UINT64_C(0xe7d34c64a9c85d44), UINT64_C(0x60dbbca87196b617) },
    { UINT64_C(0x90e40fbeea1d3a4a), UINT64_C(0xbc8955e946fe31ce) },
    { UINT64_C(0xb51d13aea4a488dd), UINT64_C(0x6babab6398bdbe42) },
    { UINT64_C(0xe264589a4dcdab14), UINT64_C(0xc696963c7eed2dd2) },
    { UINT64_C(0x8d7eb76070a08aec), UINT64_C(0xfc1e1de5cf543ca3) },
    { UINT64_C(0xb0de65388cc8ada8), UINT64_C(0x3b25a55f43294bcc) },
    { UINT64_C(0xdd15fe86affad912), UINT64_C(0x49ef0eb713f39ebf) },
    { UINT64_C(0x8a2dbf142dfcc7ab), UINT64_C(0x6e3569326c784338) },
    { UINT64_C(0xacb92ed9397bf996), UINT64_C(0x49c2c37f07965405) },
    { UINT64_C(0xd7e77a8f87daf7fb), UINT64_C(0xdc33745ec97be907) },
    { UINT64_C(0x86f0ac99b4e8dafd), UINT64_C(0x69a028bb3ded71a4) },
    { UINT64_C(0xa8acd7c0222311bc), UINT64_C(0xc40832ea0d68ce0d) },
    { UINT64_C(0xd2d80db02aabd62b), UINT64_C(0xf50a3fa490c30191) },
    { UINT64_C(0x83c7088e1aab65db), UINT64_C(0x792667c6da79e0fb) },
    { UINT64_C(0xa4b8cab1a1563f52), UINT64_C(0x577001b891185939) },
    { UINT64_C(0xcde6fd5e09abcf26), UINT64_C(0xed4c0226b55e6f87) },
    { UINT64_C(0x80b05e5ac60b6178), UINT64_C(0x544f8158315b05b5) },
    { UINT64_C(0xa0dc75f1778e39d6), UINT64_C(0x696361ae3db1c722) },
    { UINT64_C(0xc913936dd571c84c), UINT64_C(0x03bc3a19cd1e38ea) },
    { UINT64_C(0xfb5878494ace3a5f), UINT64_C(0x04ab48a04065c724) },
    { UINT64_C(0x9d174b2dcec0e47b), UINT64_C(0x62eb0d64283f9c77) },
    { UINT64_C(0xc45d1df942711d9a), UINT64_C(0x3ba5d0bd324f8395) },
    { UINT64_C(0xf5746577930d6500), UINT64_C(0xca8f44ec7ee3647a) },
    { UINT64_C(0x9968bf6abbe85f20), UINT64_C(0x7e998b13cf4e1ecc) },
    { UINT64_C(0xbfc2ef456ae276e8), UINT64_C(0x9e3fedd8c321a67f) },
    { UINT64_C(0xefb3ab16c59b14a2), UINT64_C(0xc5cfe94ef3ea101f) },
    { UINT64_C(0x95d04aee3b80ece5), UINT64_C(0xbba1f1d158724a13) },
    { UINT64_C(0xbb445da9ca61281f), UINT64_C(0x2a8a6e45ae8edc98) },
    { UINT64_C(0xea1575143cf97226), UINT64_C(0xf52d09d71a3293be) },
    { UINT64_C(0x924d692ca61be758), UINT64_C(0x593c2626705f9c57) },
    { UINT64_C(0xb6e0c377cfa2e12e), UINT64_C(0x6f8b2fb00c77836d) },
    { UINT64_C(0xe498f455c38b997a), UINT64_C(0x0b6dfb9c0f956448) },
    { UINT64_C(0x8edf98b59a373fec), UINT64_C(0x4724bd4189bd5ead) },
    { UINT64_C(0xb2977ee300c50fe7), UINT64_C(0x58edec91ec2cb658) },
    { UINT64_C(0xdf3d5e9bc0f653e1), UINT64_C(0x2f2967b66737e3ee) },
    { UINT64_C(0x8b865b215899f46c), UINT64_C(0xbd79e0d20082ee75) },
    { UINT64_C(0xae67f1e9aec07187), UINT64_C(0xecd8590680a3aa12) },
    { UINT64_C(0xda01ee641a708de9), UINT64_C(0xe80e6f4820cc9496) },
    { UINT64_C(0x884134fe908658b2), UINT64_C(0x3109058d147fdcde) },
    { UINT64_C(0xaa51823e34a7eede), UINT64_C(0xbd4b46f0599fd416) },
    { UINT64_C(0xd4e5e2cdc1d1ea96), UINT64_C(0x6c9e18ac7007c91b) },
    { UINT64_C(0x850fadc09923329e), UINT64_C(0x03e2cf6bc604ddb1) },
    { UINT64_C(0xa6539930bf6bff45), UINT64_C(0x84db8346b786151d) },
    { UINT64_C(0xcfe87f7cef46ff16), UINT64_C(0xe612641865679a64) },
    { UINT64_C(0x81f14fae158c5f6e), UINT64_C(0x4fcb7e8f3f60c07f) },
    { UINT64_C(0xa26da3999aef7749), UINT64_C(0xe3be5e330f38f09e) },
    { UINT64_C(0xcb090c8001ab551c), UINT64_C(0x5cadf5bfd3072cc6) },
    { UINT64_C(0xfdcb4fa002162a63), UINT64_C(0x73d9732fc7c8f7f7) },
    { UINT64_C(0x9e9f11c4014dda7e), UINT64_C(0x2867e7fddcdd9afb) },
    { UINT64_C(0xc646d63501a1511d), UINT64_C(0xb281e1fd541501b9) },
    { UINT64_C(0xf7d88bc24209a565), UINT64_C(0x1f225a7ca91a4227) },
    { UINT64_C(0x9ae757596946075f), UINT64_C(0x3375788de9b06959) },
    { UINT64_C(0xc1a12d2fc3978937), UINT64_C(0x0052d6b1641c83af) },
    { UINT64_C(0xf209787bb47d6b84), UINT64_C(0xc0678c5dbd23a49b) },
    { UINT64_C(0x9745eb4d50ce6332), UINT64_C(0xf840b7ba963646e1) },
    { UINT64_C(0xbd176620a501fbff), UINT64_C(0xb650e5a93bc3d899) },
    { UINT64_C(0xec5d3fa8ce427aff), UINT64_C(0xa3e51f138ab4cebf) },
    { UINT64_C(0x93ba47c980e98cdf), UINT64_C(0xc66f336c36b10138) },
    { UINT64_C(0xb8a8d9bbe123f017), UINT64_C(0xb80b0047445d4185) },
    { UINT64_C(0xe6d3102ad96cec1d), UINT64_C(0xa60dc059157491e6) },
    { UINT64_C(0x9043ea1ac7e41392), UINT64_C(0x87c89837ad68db30) },
    { UINT64_C(0xb454e4a179dd1877), UINT64_C(0x29babe4598c311fc) },
    { UINT64_C(0xe16a1dc9d8545e94), UINT64_C(0xf4296dd6fef3d67b) },
    { UINT64_C(0x8ce2529e2734bb1d), UINT64_C(0x1899e4a65f58660d) },
    { UINT64_C(0xb01ae745b101e9e4), UINT64_C(0x5ec05dcff72e7f90) },
    { UINT64_C(0xdc21a1171d42645d), UINT64_C(0x76707543f4fa1f74) },
    { UINT64_C(0x899504ae72497eba), UINT64_C(0x6a06494a791c53a9) },
    { UINT64_C(0xabfa45da0edbde69), UINT64_C(0x0487db9d17636893) },
    { UINT64_C(0xd6f8d7509292d603), UINT64_C(0x45a9d2845d3c42b7) },
    { UINT64_C(0x865b86925b9bc5c2), UINT64_C(0x0b8a2392ba45a9b3) },
    { UINT64_C(0xa7f26836f282b732), UINT64_C(0x8e6cac7768d7141f) },
    { UINT64_C(0xd1ef0244af2364ff), UINT64_C(0x3207d795430cd927) },
    { UINT64_C(0x8335616aed761f1f), UINT64_C(0x7f44e6bd49e807b9) },
    { UINT64_C(0xa402b9c5a8d3a6e7), UINT64_C(0x5f16206c9c6209a7) },
    { UINT64_C(0xcd036837130890a1), UINT64_C(0x36dba887c37a8c10) },
    { UINT64_C(0x802221226be55a64), UINT64_C(0xc2494954da2c978a) },
    { UINT64_C(0xa02aa96b06deb0fd), UINT64_C(0xf2db9baa10b7bd6d) },
    { UINT64_C(0xc83553c5c8965d3d), UINT64_C(0x6f92829494e5acc8) },
    { UINT64_C(0xfa42a8b73abbf48c), UINT64_C(0xcb772339ba1f17fa) },
    { UINT64_C(0x9c69a97284b578d7), UINT64_C(0xff2a760414536efc) },
    { UINT64_C(0xc38413cf25e2d70d), UINT64_C(0xfef5138519684abb) },
    { UINT64_C(0xf46518c2ef5b8cd1), UINT64_C(0x7eb258665fc25d6a) },
    { UINT64_C(0x98bf2f79d5993802), UINT64_C(0xef2f773ffbd97a62) },
    { UINT64_C(0xbeeefb584aff8603), UINT64_C(0xaafb550ffacfd8fb) },
    { UINT64_C(0xeeaaba2e5dbf6784), UINT64_C(0x95ba2a53f983cf39) },
    { UINT64_C(0x952ab45cfa97a0b2), UINT64_C(0xdd945a747bf26184) },
    { UINT64_C(0xba756174393d88df), UINT64_C(0x94f971119aeef9e5) },
    { UINT64_C(0xe912b9d1478ceb17), UINT64_C(0x7a37cd5601aab85e) },
    { UINT64_C(0x91abb422ccb812ee), UINT64_C(0xac62e055c10ab33b) },
    { UINT64_C(0xb616a12b7fe617aa), UINT64_C(0x577b986b314d600a) },
    { UINT64_C(0xe39c49765fdf9d94), UINT64_C(0xed5a7e85fda0b80c) },
    { UINT64_C(0x8e41ade9fbebc27d), UINT64_C(0x14588f13be847308) },
    { UINT64_C(0xb1d219647ae6b31c), UINT64_C(0x596eb2d8ae258fc9) },
    { UINT64_C(0xde469fbd99a05fe3), UINT64_C(0x6fca5f8ed9aef3bc) },
    { UINT64_C(0x8aec23d680043bee), UINT64_C(0x25de7bb9480d5855) },
    { UINT64_C(0xada72ccc20054ae9), UINT64_C(0xaf561aa79a10ae6b) },
    { UINT64_C(0xd910f7ff28069da4), UINT64_C(0x1b2ba1518094da05) },
    { UINT64_C(0x87aa9aff79042286), UINT64_C(0x90fb44d2f05d0843) },
    { UINT64_C(0xa99541bf57452b28), UINT64_C(0x353a1607ac744a54) },
    { UINT64_C(0xd3fa922f2d1675f2), UINT64_C(0x42889b8997915ce9) },
    { UINT64_C(0x847c9b5d7c2e09b7), UINT64_C(0x69956135febada12) },
    { UINT64_C(0xa59bc234db398c25), UINT64_C(0x43fab9837e699096) },
    { UINT64_C(0xcf02b2c21207ef2e), UINT64_C(0x94f967e45e03f4bc) },
    { UINT64_C(0x8161afb94b44f57d), UINT64_C(0x1d1be0eebac278f6) },
    { UINT64_C(0xa1ba1ba79e1632dc), UINT64_C(0x6462d92a69731733) },
    { UINT64_C(0xca28a291859bbf93), UINT64_C(0x7d7b8f7503cfdcff) },
    { UINT64_C(0xfcb2cb35e702af78), UINT64_C(0x5cda735244c3d43f) },
    { UINT64_C(0x9defbf01b061adab), UINT64_C(0x3a0888136afa64a8) },
    { UINT64_C(0xc56baec21c7a1916), UINT64_C(0x088aaa1845b8fdd1) },
    { UINT64_C(0xf6c69a72a3989f5b), UINT64_C(0x8aad549e57273d46) },
    { UINT64_C(0x9a3c2087a63f6399), UINT64_C(0x36ac54e2f678864c) },
    { UINT64_C(0xc0cb28a98fcf3c7f), UINT64_C(0x84576a1bb416a7de) },
    { UINT64_C(0xf0fdf2d3f3c30b9f), UINT64_C(0x656d44a2a11c51d6) },
    { UINT64_C(0x969eb7c47859e743), UINT64_C(0x9f644ae5a4b1b326) },
    { UINT64_C(0xbc4665b596706114), UINT64_C(0x873d5d9f0dde1fef) },
    { UINT64_C(0xeb57ff22fc0c7959), UINT64_C(0xa90cb506d155a7eb) },
    { UINT64_C(0x9316ff75dd87cbd8), UINT64_C(0x09a7f12442d588f3) },
    { UINT64_C(0xb7dcbf5354e9bece), UINT64_C(0x0c11ed6d538aeb30) },
    { UINT64_C(0xe5d3ef282a242e81), UINT64_C(0x8f1668c8a86da5fb) },
    { UINT64_C(0x8fa475791a569d10), UINT64_C(0xf96e017d694487bd) },
    { UINT64_C(0xb38d92d760ec4455), UINT64_C(0x37c981dcc395a9ad) },
    { UINT64_C(0xe070f78d3927556a), UINT64_C(0x85bbe253f47b1418) },
    { UINT64_C(0x8c469ab843b89562), UINT64_C(0x93956d7478ccec8f) },
    { UINT64_C(0xaf58416654a6babb), UINT64_C(0x387ac8d1970027b3) },
    { UINT64_C(0xdb2e51bfe9d0696a), UINT64_C(0x06997b05fcc0319f) },
    { UINT64_C(0x88fcf317f22241e2), UINT64_C(0x441fece3bdf81f04) },
    { UINT64_C(0xab3c2fddeeaad25a), UINT64_C(0xd527e81cad7626c4) },
    { UINT64_C(0xd60b3bd56a5586f1), UINT64_C(0x8a71e223d8d3b075) },
    { UINT64_C(0x85c7056562757456), UINT64_C(0xf6872d5667844e4a) },
    { UINT64_C(0xa738c6bebb12d16c), UINT64_C(0xb428f8ac016561dc) },
    { UINT64_C(0xd106f86e69d785c7), UINT64_C(0xe13336d701beba53) },
    { UINT64_C(0x82a45b450226b39c), UINT64_C(0xecc0024661173474) },
    { UINT64_C(0xa34d721642b06084), UINT64_C(0x27f002d7f95d0191) },
    { UINT64_C(0xcc20ce9bd35c78a5), UINT64_C(0x31ec038df7b441f5) },
    { UINT64_C(0xff290242c83396ce), UINT64_C(0x7e67047175a15272) },
    { UINT64_C(0x9f79a169bd203e41), UINT64_C(0x0f0062c6e984d387) },
    { UINT64_C(0xc75809c42c684dd1), UINT64_C(0x52c07b78a3e60869) },
    { UINT64_C(0xf92e0c3537826145), UINT64_C(0xa7709a56ccdf8a83) },
    { UINT64_C(0x9bbcc7a142b17ccb), UINT64_C(0x88a66076400bb692) },
    { UINT64_C(0xc2abf989935ddbfe), UINT64_C(0x6acff893d00ea436) },
    { UINT64_C(0xf356f7ebf83552fe), UINT64_C(0x0583f6b8c4124d44) },
    { UINT64_C(0x98165af37b2153de), UINT64_C(0xc3727a337a8b704b) },
    { UINT64_C(0xbe1bf1b059e9a8d6), UINT64_C(0x744f18c0592e4c5d) },
    { UINT64_C(0xeda2ee1c7064130c), UINT64_C(0x1162def06f79df74) },
    { UINT64_C(0x9485d4d1c63e8be7), UINT64_C(0x8addcb5645ac2ba9) },
    { UINT64_C(0xb9a74a0637ce2ee1), UINT64_C(0x6d953e2bd7173693) },
    { UINT64_C(0xe8111c87c5c1ba99), UINT64_C(0xc8fa8db6ccdd0438) },
    { UINT64_C(0x910ab1d4db9914a0), UINT64_C(0x1d9c9892400a22a3) },
    { UINT64_C(0xb54d5e4a127f59c8), UINT64_C(0x2503beb6d00cab4c) },
    { UINT64_C(0xe2a0b5dc971f303a), UINT64_C(0x2e44ae64840fd61e) },
    { UINT64_C(0x8da471a9de737e24), UINT64_C(0x5ceaecfed289e5d3) },
    { UINT64_C(0xb10d8e1456105dad), UINT64_C(0x7425a83e872c5f48) },
    { UINT64_C(0xdd50f1996b947518), UINT64_C(0xd12f124e28f7771a) },
    { UINT64_C(0x8a5296ffe33cc92f), UINT64_C(0x82bd6b70d99aaa70) },
    { UINT64_C(0xace73cbfdc0bfb7b), UINT64_C(0x636cc64d1001550c) },
    { UINT64_C(0xd8210befd30efa5a), UINT64_C(0x3c47f7e05401aa4f) },
    { UINT64_C(0x8714a775e3e95c78), UINT64_C(0x65acfaec34810a72) },
    { UINT64_C(0xa8d9d1535ce3b396), UINT64_C(0x7f1839a741a14d0e) },
    { UINT64_C(0xd31045a8341ca07c), UINT64_C(0x1ede48111209a051) },
    { UINT64_C(0x83ea2b892091e44d), UINT64_C(0x934aed0aab460433) },
    { UINT64_C(0xa4e4b66b68b65d60), UINT64_C(0xf81da84d56178540) },
    { UINT64_C(0xce1de40642e3f4b9), UINT64_C(0x36251260ab9d668f) },
    { UINT64_C(0x80d2ae83e9ce78f3), UINT64_C(0xc1d72b7c6b42601a) },
    { UINT64_C(0xa1075a24e4421730), UINT64_C(0xb24cf65b8612f820) },
    { UINT64_C(0xc94930ae1d529cfc), UINT64_C(0xdee033f26797b628) },
    { UINT64_C(0xfb9b7cd9a4a7443c), UINT64_C(0x169840ef017da3b2) },
    { UINT64_C(0x9d412e0806e88aa5), UINT64_C(0x8e1f289560ee864f) },
    { UINT64_C(0xc491798a08a2ad4e), UINT64_C(0xf1a6f2bab92a27e3) },
    { UINT64_C(0xf5b5d7ec8acb58a2), UINT64_C(0xae10af696774b1dc) },
    { UINT64_C(0x9991a6f3d6bf1765), UINT64_C(0xacca6da1e0a8ef2a) },
    { UINT64_C(0xbff610b0cc6edd3f), UINT64_C(0x17fd090a58d32af4) },
    { UINT64_C(0xeff394dcff8a948e), UINT64_C(0xddfc4b4cef07f5b1) },
    { UINT64_C(0x95f83d0a1fb69cd9), UINT64_C(0x4abdaf101564f98f) },
    { UINT64_C(0xbb764c4ca7a4440f), UINT64_C(0x9d6d1ad41abe37f2) },
    { UINT64_C(0xea53df5fd18d5513), UINT64_C(0x84c86189216dc5ee) },
    { UINT64_C(0x92746b9be2f8552c), UINT64_C(0x32fd3cf5b4e49bb5) },
    { UINT64_C(0xb7118682dbb66a77), UINT64_C(0x3fbc8c33221dc2a2) },
    { UINT64_C(0xe4d5e82392a40515), UINT64_C(0x0fabaf3feaa5334b) },
    { UINT64_C(0x8f05b1163ba6832d), UINT64_C(0x29cb4d87f2a7400f) },
    { UINT64_C(0xb2c71d5bca9023f8), UINT64_C(0x743e20e9ef511013) },
    { UINT64_C(0xdf78e4b2bd342cf6), UINT64_C(0x914da9246b255417) },
    { UINT64_C(0x8bab8eefb6409c1a), UINT64_C(0x1ad089b6c2f7548f) },
    { UINT64_C(0xae9672aba3d0c320), UINT64_C(0xa184ac2473b529b2) },
    { UINT64_C(0xda3c0f568cc4f3e8), UINT64_C(0xc9e5d72d90a2741f) },
    { UINT64_C(0x8865899617fb1871), UINT64_C(0x7e2fa67c7a658893) },
    { UINT64_C(0xaa7eebfb9df9de8d), UINT64_C(0xddbb901b98feeab8) },
    { UINT64_C(0xd51ea6fa85785631), UINT64_C(0x552a74227f3ea566) },
    { UINT64_C(0x8533285c936b35de), UINT64_C(0xd53a88958f872760) },
    { UINT64_C(0xa67ff273b8460356), UINT64_C(0x8a892abaf368f138) },
    { UINT64_C(0xd01fef10a657842c), UINT64_C(0x2d2b7569b0432d86) },
    { UINT64_C(0x8213f56a67f6b29b), UINT64_C(0x9c3b29620e29fc74) },
    { UINT64_C(0xa298f2c501f45f42), UINT64_C(0x8349f3ba91b47b90) },
    { UINT64_C(0xcb3f2f7642717713), UINT64_C(0x241c70a936219a74) },
    { UINT64_C(0xfe0efb53d30dd4d7), UINT64_C(0xed238cd383aa0111) },
    { UINT64_C(0x9ec95d1463e8a506), UINT64_C(0xf4363804324a40ab) },
    { UINT64_C(0xc67bb4597ce2ce48), UINT64_C(0xb143c6053edcd0d6) },
    { UINT64_C(0xf81aa16fdc1b81da), UINT64_C(0xdd94b7868e94050b) },
    { UINT64_C(0x9b10a4e5e9913128), UINT64_C(0xca7cf2b4191c8327) },
    { UINT64_C(0xc1d4ce1f63f57d72), UINT64_C(0xfd1c2f611f63a3f1) },
    { UINT64_C(0xf24a01a73cf2dccf), UINT64_C(0xbc633b39673c8ced) },
    { UINT64_C(0x976e41088617ca01), UINT64_C(0xd5be0503e085d814) },
    { UINT64_C(0xbd49d14aa79dbc82), UINT64_C(0x4b2d8644d8a74e19) },
    { UINT64_C(0xec9c459d51852ba2), UINT64_C(0xddf8e7d60ed1219f) },
    { UINT64_C(0x93e1ab8252f33b45), UINT64_C(0xcabb90e5c942b504) },
    { UINT64_C(0xb8da1662e7b00a17), UINT64_C(0x3d6a751f3b936244) },
    { UINT64_C(0xe7109bfba19c0c9d), UINT64_C(0x0cc512670a783ad5) },
    { UINT64_C(0x906a617d450187e2), UINT64_C(0x27fb2b80668b24c6) },
    { UINT64_C(0xb484f9dc9641e9da), UINT64_C(0xb1f9f660802dedf7) },
    { UINT64_C(0xe1a63853bbd26451), UINT64_C(0x5e7873f8a0396974) },
    { UINT64_C(0x8d07e33455637eb2), UINT64_C(0xdb0b487b6423e1e9) },
    { UINT64_C(0xb049dc016abc5e5f), UINT64_C(0x91ce1a9a3d2cda63) },
    { UINT64_C(0xdc5c5301c56b75f7), UINT64_C(0x7641a140cc7810fc) },
    { UINT64_C(0x89b9b3e11b6329ba), UINT64_C(0xa9e904c87fcb0a9e) },
    { UINT64_C(0xac2820d9623bf429), UINT64_C(0x546345fa9fbdcd45) },
    { UINT64_C(0xd732290fbacaf133), UINT64_C(0xa97c177947ad4096) },
    { UINT64_C(0x867f59a9d4bed6c0), UINT64_C(0x49ed8eabcccc485e) },
    { UINT64_C(0xa81f301449ee8c70), UINT64_C(0x5c68f256bfff5a75) },
    { UINT64_C(0xd226fc195c6a2f8c), UINT64_C(0x73832eec6fff3112) },
    { UINT64_C(0x83585d8fd9c25db7), UINT64_C(0xc831fd53c5ff7eac) },
    { UINT64_C(0xa42e74f3d032f525), UINT64_C(0xba3e7ca8b77f5e56) },
    { UINT64_C(0xcd3a1230c43fb26f), UINT64_C(0x28ce1bd2e55f35ec) },
    { UINT64_C(0x80444b5e7aa7cf85), UINT64_C(0x7980d163cf5b81b4) },
    { UINT64_C(0xa0555e361951c366), UINT64_C(0xd7e105bcc3326220) },
    { UINT64_C(0xc86ab5c39fa63440), UINT64_C(0x8dd9472bf3fefaa8) },
    { UINT64_C(0xfa856334878fc150), UINT64_C(0xb14f98f6f0feb952) },
    { UINT64_C(0x9c935e00d4b9d8d2), UINT64_C(0x6ed1bf9a569f33d4) },
    { UINT64_C(0xc3b8358109e84f07), UINT64_C(0x0a862f80ec4700c9) },
    { UINT64_C(0xf4a642e14c6262c8), UINT64_C(0xcd27bb612758c0fb) },
    { UINT64_C(0x98e7e9cccfbd7dbd), UINT64_C(0x8038d51cb897789d) },
    { UINT64_C(0xbf21e44003acdd2c), UINT64_C(0xe0470a63e6bd56c4) },
    { UINT64_C(0xeeea5d5004981478), UINT64_C(0x1858ccfce06cac75) },
    { UINT64_C(0x95527a5202df0ccb), UINT64_C(0x0f37801e0c43ebc9) },
    { UINT64_C(0xbaa718e68396cffd), UINT64_C(0xd30560258f54e6bb) },
    { UINT64_C(0xe950df20247c83fd), UINT64_C(0x47c6b82ef32a206a) },
    { UINT64_C(0x91d28b7416cdd27e), UINT64_C(0x4cdc331d57fa5442) },
    { UINT64_C(0xb6472e511c81471d), UINT64_C(0xe0133fe4adf8e953) },
    { UINT64_C(0xe3d8f9e563a198e5), UINT64_C(0x58180fddd97723a7) },
    { UINT64_C(0x8e679c2f5e44ff8f), UINT64_C(0x570f09eaa7ea7649) },
    { UINT64_C(0xb201833b35d63f73), UINT64_C(0x2cd2cc6551e513db) },
    { UINT64_C(0xde81e40a034bcf4f), UINT64_C(0xf8077f7ea65e58d2) },
    { UINT64_C(0x8b112e86420f6191), UINT64_C(0xfb04afaf27faf783) },
    { UINT64_C(0xadd57a27d29339f6), UINT64_C(0x79c5db9af1f9b564) },
    { UINT64_C(0xd94ad8b1c7380874), UINT64_C(0x18375281ae7822bd) },
    { UINT64_C(0x87cec76f1c830548), UINT64_C(0x8f2293910d0b15b6) },
    { UINT64_C(0xa9c2794ae3a3c69a), UINT64_C(0xb2eb3875504ddb23) },
    { UINT64_C(0xd433179d9c8cb841), UINT64_C(0x5fa60692a46151ec) },
    { UINT64_C(0x849feec281d7f328), UINT64_C(0xdbc7c41ba6bcd334) },
    { UINT64_C(0xa5c7ea73224deff3), UINT64_C(0x12b9b522906c0801) },
    { UINT64_C(0xcf39e50feae16bef), UINT64_C(0xd768226b34870a01) },
    { UINT64_C(0x81842f29f2cce375), UINT64_C(0xe6a1158300d46641) },
    { UINT64_C(0xa1e53af46f801c53), UINT64_C(0x60495ae3c1097fd1) },
    { UINT64_C(0xca5e89b18b602368), UINT64_C(0x385bb19cb14bdfc5) },
    { UINT64_C(0xfcf62c1dee382c42), UINT64_C(0x46729e03dd9ed7b6) },
    { UINT64_C(0x9e19db92b4e31ba9), UINT64_C(0x6c07a2c26a8346d2) },
    { UINT64_C(0xc5a05277621be293), UINT64_C(0xc7098b7305241886) },
    { UINT64_C(0xf70867153aa2db38), UINT64_C(0xb8cbee4fc66d1ea8) },
};

static inline void db64_remove_trailing_zeros(uint64_t *sig, int *exp) {
    uint64_t n = *sig, r;
    int b, s;
    r = rotr64(n * UINT64_C(28999941890838049), 8);    b = r < UINT64_C(184467440738);        s = b;         if (b) n = r;
    r = rotr64(n * UINT64_C(182622766329724561), 4);   b = r < UINT64_C(1844674407370956);    s = s * 2 + b; if (b) n = r;
    r = rotr64(n * UINT64_C(10330176681277348905), 2); b = r < UINT64_C(184467440737095517);  s = s * 2 + b; if (b) n = r;
    r = rotr64(n * UINT64_C(14757395258967641293), 1); b = r < UINT64_C(1844674407370955162); s = s * 2 + b; if (b) n = r;
    *sig = n;
    *exp += s;
}

/* Nonzero finite only. */
static db_dec db64_to_decimal(uint64_t bits) {
    uint64_t two_fc = (bits & UINT64_C(0x000FFFFFFFFFFFFF)) << 1;
    int      ebits  = (int)((bits >> 52) & 0x7FF);
    int      even   = (bits & 1) == 0;
    int      e;
    db_dec   out;

    if (ebits != 0) {
        e = ebits - 1023 - 52;

        if (two_fc == 0) {
            int      minus_k = floor_log10_pow2_minus_log10_4_3(e);
            int      beta    = e + floor_log2_pow10(-minus_k);
            u128     cache   = db64_cache[-minus_k - DB64_MIN_K];
            uint64_t xi      = (cache.hi - (cache.hi >> (52 + 2))) >> (64 - 52 - 1 - beta);
            uint64_t zi      = (cache.hi + (cache.hi >> (52 + 1))) >> (64 - 52 - 1 - beta);
            uint64_t sig;

            if (!(e >= 2 && e <= 3)) ++xi;

            /* zi / 10; zi < 2^57 keeps the 64-bit magic exact. */
            sig = umul128_hi(zi, UINT64_C(1844674407370955162));
            if (sig * 10 >= xi) {
                out.sig = sig;
                out.exp = minus_k + 1;
                db64_remove_trailing_zeros(&out.sig, &out.exp);
                return out;
            }

            sig = ((cache.hi >> (64 - 52 - 2 - beta)) + 1) / 2;
            if ((sig & 1) && e >= DB64_TIE_LO && e <= DB64_TIE_HI) {
                --sig;
            } else if (sig < xi) {
                ++sig;
            }
            out.sig = sig;
            out.exp = minus_k;
            return out;
        }

        two_fc |= UINT64_C(1) << 53;
    } else {
        e = -1022 - 52;
    }

    {
        /* Step 1. kappa = 2. */
        int      minus_k = floor_log10_pow2(e) - 2;
        u128     cache   = db64_cache[-minus_k - DB64_MIN_K];
        int      beta    = e + floor_log2_pow10(-minus_k);
        uint64_t deltai  = cache.hi >> (64 - 1 - beta);              /* 100 <= deltai < 1000 */

        /* z: upper 128 of the 192-bit product (2f_c + 1) 2^beta * cache. */
        uint64_t u  = (two_fc | 1) << beta;
        u128     zr = umul128(u, cache.hi);
        uint64_t lo = umul128_hi(u, cache.lo);
        zr.lo += lo;
        zr.hi += zr.lo < lo;
        {
            uint64_t zi    = zr.hi;
            int      z_int = zr.lo == 0;

            /* Step 2. zi / 1000, zi < 2^53 * 1000. */
            uint64_t sig = umul128_hi(zi, UINT64_C(4722366482869645214)) >> 8;
            uint64_t r   = zi - 1000 * sig;

            do {
                if (r < deltai) {
                    if ((r | (uint64_t)!z_int | (uint64_t)even) == 0) {
                        --sig;
                        r = 1000;
                        break;
                    }
                } else if (r > deltai) {
                    break;
                } else {
                    /* Low 128 of (2f_c - 1) * cache; beta in [1, 63]. */
                    uint64_t x     = two_fc - 1;
                    u128     xl    = umul128(x, cache.lo);
                    uint64_t xh    = x * cache.hi + xl.hi;
                    int      x_par = (int)((xh >> (64 - beta)) & 1);
                    int      x_int = ((xh << beta) | (xl.lo >> (64 - beta))) == 0;
                    if (!(x_par | (x_int & even))) break;
                }
                out.sig = sig;
                out.exp = minus_k + 2 + 1;
                db64_remove_trailing_zeros(&out.sig, &out.exp);
                return out;
            } while (0);

            /* Step 3. */
            sig *= 10;
            {
                uint64_t dist         = r - deltai / 2 + 50;
                int      approx_y_par = ((dist ^ 50) & 1) != 0;
                uint32_t prod         = (uint32_t)dist * UINT32_C(656);   /* dist <= 1000 */
                int      divisible    = (prod & 0xFFFF) < UINT32_C(656);
                dist = prod >> 16;                                         /* dist / 100 */
                sig += dist;

                if (divisible) {
                    u128     yl    = umul128(two_fc, cache.lo);
                    uint64_t yh    = two_fc * cache.hi + yl.hi;
                    int      y_par = (int)((yh >> (64 - beta)) & 1);
                    int      y_int = ((yh << beta) | (yl.lo >> (64 - beta))) == 0;
                    if (y_par != approx_y_par) {
                        --sig;
                    } else if ((sig & 1) & y_int) {
                        --sig;
                    }
                }
            }
            out.sig = sig;
            out.exp = minus_k + 2;
            return out;
        }
    }
}

/* ===================================================================== */
/*  Exact digits: a small bignum                                          */
/* ===================================================================== */

/* Limb budget. The worst case is the smallest binary128 subnormal, 2^-16494:
 * the scaled remainder reaches m * 2^2 * 10^4966 < 2^16612 bits, and one
 * more decade during generation. 640 limbs is 20480 bits. */
#define BN_LIMBS 640

typedef struct {
    int      n;              /* limbs in use; d[n-1] != 0 unless n == 0 */
    uint32_t d[BN_LIMBS];
} bn;

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

/* A decoded finite nonzero value: v = m * 2^e, of a format with p
 * significand bits (hidden bit included) whose subnormals sit at e_min. */
typedef struct {
    u128 m;
    int  e;
    int  p;
    int  e_min;
} fval;

/* floor(log10(v)) + 1 or one less: the estimate the fixups below correct. */
static int estimate_k(const fval *v) {
    int l2 = v->e + bitlen_u128(v->m) - 1;              /* 2^l2 <= v < 2^(l2+1) */
    double l = (double)l2 * 0.30102999566398119521;     /* < 5e-12 off; no n*log10(2) is that near an integer for |n| < 2^15 */
    int f = (int)l;
    if ((double)f > l) --f;
    return f + 1;
}

/* The scratch every exact routine works in. Off the stack: ~13 KB. */
typedef struct { bn r, s, mp, mm, t; } exact_ws;

/* Shortest digits that read back as v under nearest-to-even, ties to the
 * even digit. Writes ASCII digits, returns the count n and k such that
 * v ~ 0.d1...dn * 10^k. Burger & Dybvig's free-format algorithm with the
 * "both ends fit" case rounding to even instead of up. */
static int exact_shortest(const fval *v, unsigned char *digits, int *k_out, exact_ws *w) {
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
 * ties to even. Same output convention as exact_shortest. */
static int exact_fixed(const fval *v, int ndig, unsigned char *digits, int *k_out, exact_ws *w) {
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

/* ===================================================================== */
/*  Decoding                                                              */
/* ===================================================================== */

enum { FC_FINITE, FC_ZERO, FC_INF, FC_NAN };

typedef struct {
    int  cls;
    fval v;
} fclass;

/* IEEE-shaped: sign | exp_bits | mant_bits, hidden bit, bias 2^(eb-1)-1.
 * finite_only is the OCP E4M3FN shape: the top exponent is ordinary except
 * for the all-ones pattern, which is NaN; there is no infinity. */
static fclass decode_ieee(uint64_t hi, uint64_t lo, int mant_bits, int exp_bits, int finite_only) {
    fclass   f;
    int      bias   = (1 << (exp_bits - 1)) - 1;
    int      ebits;
    u128     m;

    if (mant_bits >= 64) {
        ebits = (int)((hi >> (mant_bits - 64)) & ((1u << exp_bits) - 1));
        m.hi  = hi & ((UINT64_C(1) << (mant_bits - 64)) - 1);
        m.lo  = lo;
    } else {
        ebits = (int)((lo >> mant_bits) & ((1u << exp_bits) - 1));
        m.hi  = 0;
        m.lo  = lo & ((UINT64_C(1) << mant_bits) - 1);
    }

    f.v.p     = mant_bits + 1;
    f.v.e_min = 1 - bias - mant_bits;

    if (ebits == (1 << exp_bits) - 1) {
        int all_ones = mant_bits >= 64 ? (m.hi == ((UINT64_C(1) << (mant_bits - 64)) - 1) && m.lo == ~UINT64_C(0))
                                       : (m.lo == ((UINT64_C(1) << mant_bits) - 1));
        if (finite_only) {
            if (all_ones) { f.cls = FC_NAN; return f; }
        } else {
            f.cls = (m.hi | m.lo) == 0 ? FC_INF : FC_NAN;
            return f;
        }
    }
    if (ebits == 0) {
        if ((m.hi | m.lo) == 0) { f.cls = FC_ZERO; return f; }
        f.v.e = f.v.e_min;
    } else {
        if (mant_bits >= 64) m.hi |= UINT64_C(1) << (mant_bits - 64);
        else                 m.lo |= UINT64_C(1) << mant_bits;
        f.v.e = ebits - bias - mant_bits;
    }
    f.v.m = m;
    f.cls = FC_FINITE;
    return f;
}

/* x87 extended: sign | 15 exponent | 64 significand with an explicit
 * integer bit. Every non-canonical encoding is read by its arithmetic
 * value: pseudo-denormals as denormals, a zero significand as zero. */
static fclass decode_x87(uint64_t mant, unsigned se) {
    fclass f;
    int    ebits = (int)(se & 0x7FFF);

    f.v.p     = 64;
    f.v.e_min = 1 - 16383 - 63;
    f.v.m.hi  = 0;
    f.v.m.lo  = mant;

    if (ebits == 0x7FFF) {
        f.cls = (mant << 1) == 0 ? FC_INF : FC_NAN;
        return f;
    }
    if (mant == 0) { f.cls = FC_ZERO; return f; }
    f.v.e = (ebits == 0 ? 1 : ebits) - 16383 - 63;
    f.cls = FC_FINITE;
    return f;
}

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

static int write_shortest(unsigned char *out, size_t cap, db_dec d, unsigned char conv, int p) {
    int n = digit_count_u64(d.sig);
    return layout_short(out, cap, d.sig, NULL, n, n - 1 + d.exp, conv == 'e' || conv == 'E' ? conv : 'g', p);
}

/* fast: 0, 32 or 64, the Dragonbox path usable for the shortest form of
 * this value; bits is the pattern it takes. max_digits is the format's P. */
static int format_float(unsigned char *out, size_t cap, const fclass *f, uint64_t bits, int fast,
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
        if (fast == 32) return write_shortest(out, cap, db32_to_decimal((uint32_t)bits), conv, max_digits);
        if (fast == 64) return write_shortest(out, cap, db64_to_decimal(bits), conv, max_digits);
        {
            unsigned char digits[48];
            exact_ws      w;
            int           n, k;
            n = exact_shortest(&f->v, digits, &k, &w);
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
        n = exact_fixed(&f->v, ndig, digits, &k, &w);
        if (conv == 'g') {
            while (n > 1 && digits[n - 1] == '0') --n;
        }
        layout(&em, digits, n, k - 1, conv, ndig);
        if (digits != stack_digits) kairo_rt_fmt_free(digits);
    }
    return (int)(em.pos < cap ? em.pos : cap);
}

/* ===================================================================== */
/*  Entry points                                                          */
/* ===================================================================== */

int kairo_rt_fmt_f16(unsigned char *out, size_t cap, uint16_t bits, int prec, unsigned char conv) {
    fclass f = decode_ieee(0, bits, 10, 5, 0);
    return format_float(out, cap, &f, bits, 0, 5, prec, conv);
}

int kairo_rt_fmt_bf16(unsigned char *out, size_t cap, uint16_t bits, int prec, unsigned char conv) {
    fclass f = decode_ieee(0, bits, 7, 8, 0);
    return format_float(out, cap, &f, bits, 0, 4, prec, conv);
}

int kairo_rt_fmt_f8e4m3(unsigned char *out, size_t cap, uint8_t bits, int prec, unsigned char conv) {
    fclass f = decode_ieee(0, bits, 3, 4, 1);
    return format_float(out, cap, &f, bits, 0, 3, prec, conv);
}

int kairo_rt_fmt_f8e5m2(unsigned char *out, size_t cap, uint8_t bits, int prec, unsigned char conv) {
    fclass f = decode_ieee(0, bits, 2, 5, 0);
    return format_float(out, cap, &f, bits, 0, 2, prec, conv);
}

int kairo_rt_fmt_f32(unsigned char *out, size_t cap, float v, int prec, unsigned char conv) {
    uint32_t bits;
    fclass   f;
    memcpy(&bits, &v, sizeof bits);
    if (prec < 0 && ((bits >> 23) & 0xFF) != 0xFF && (bits << 1) != 0) {
        return write_shortest(out, cap, db32_to_decimal(bits), conv, 9);
    }
    f = decode_ieee(0, bits, 23, 8, 0);
    return format_float(out, cap, &f, bits, 32, 9, prec, conv);
}

int kairo_rt_fmt_f64(unsigned char *out, size_t cap, double v, int prec, unsigned char conv) {
    uint64_t bits;
    fclass   f;
    memcpy(&bits, &v, sizeof bits);
    if (prec < 0 && ((bits >> 52) & 0x7FF) != 0x7FF && (bits << 1) != 0) {
        return write_shortest(out, cap, db64_to_decimal(bits), conv, 17);
    }
    f = decode_ieee(0, bits, 52, 11, 0);
    return format_float(out, cap, &f, bits, 64, 17, prec, conv);
}

int kairo_rt_fmt_f128(unsigned char *out, size_t cap, uint64_t hi, uint64_t lo, int prec, unsigned char conv) {
    fclass f = decode_ieee(hi, lo, 112, 15, 0);
    return format_float(out, cap, &f, 0, 0, 36, prec, conv);
}

int kairo_rt_fmt_f80(unsigned char *out, size_t cap, long double v, int prec, unsigned char conv) {
#if LDBL_MANT_DIG == 64
    /* Little-endian x87: 8 bytes of significand, then sign|exponent. */
    unsigned char raw[sizeof(long double)];
    uint64_t      mant;
    uint16_t      se;
    fclass        f;
    memcpy(raw, &v, sizeof raw);
    memcpy(&mant, raw, 8);
    memcpy(&se, raw + 8, 2);
    f = decode_x87(mant, se);
    return format_float(out, cap, &f, 0, 0, 21, prec, conv);
#elif LDBL_MANT_DIG == 53
    return kairo_rt_fmt_f64(out, cap, (double)v, prec, conv);
#elif LDBL_MANT_DIG == 113
    unsigned char raw[16];
    uint64_t      hi, lo;
    memcpy(raw, &v, sizeof raw);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    memcpy(&hi, raw, 8);
    memcpy(&lo, raw + 8, 8);
#else
    memcpy(&lo, raw, 8);
    memcpy(&hi, raw + 8, 8);
#endif
    return kairo_rt_fmt_f128(out, cap, hi, lo, prec, conv);
#else
#error "long double is none of binary64, x87 extended or binary128"
#endif
}
