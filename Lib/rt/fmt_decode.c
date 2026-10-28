/* --- The Kairo Project ----------------------- Lib/rt/fmt_decode.c --- */
/*
 *   A float's bit pattern -> its class and, when finite and nonzero, its
 *   exact value m * 2^e.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt_impl.h"

/* ===================================================================== */
/*  Decoding                                                              */
/* ===================================================================== */
/* IEEE-shaped: sign | exp_bits | mant_bits, hidden bit, bias 2^(eb-1)-1.
 * finite_only is the OCP E4M3FN shape: the top exponent is ordinary except
 * for the all-ones pattern, which is NaN; there is no infinity. */
fclass kairo_rt_fmt_decode_ieee_(uint64_t hi, uint64_t lo, int mant_bits, int exp_bits, int finite_only) {
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
fclass kairo_rt_fmt_decode_x87_(uint64_t mant, unsigned se) {
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
