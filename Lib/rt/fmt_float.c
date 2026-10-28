/* --- The Kairo Project ------------------------ Lib/rt/fmt_float.c --- */
/*
 *   The entry points rt/fmt.h declares, one per float format: decode the
 *   pattern, then format_float (fmt_layout.c). f32 and f64 take
 *   Dragonbox's shortest digits directly when they can.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt_impl.h"

#include <float.h>
#include <string.h>

/* ===================================================================== */
/*  Entry points                                                          */
/* ===================================================================== */

int kairo_rt_fmt_f16(unsigned char *out, size_t cap, uint16_t bits, int prec, unsigned char conv) {
    fclass f = kairo_rt_fmt_decode_ieee_(0, bits, 10, 5, 0);
    return kairo_rt_fmt_format_float_(out, cap, &f, bits, 0, 5, prec, conv);
}

int kairo_rt_fmt_bf16(unsigned char *out, size_t cap, uint16_t bits, int prec, unsigned char conv) {
    fclass f = kairo_rt_fmt_decode_ieee_(0, bits, 7, 8, 0);
    return kairo_rt_fmt_format_float_(out, cap, &f, bits, 0, 4, prec, conv);
}

int kairo_rt_fmt_f8e4m3(unsigned char *out, size_t cap, uint8_t bits, int prec, unsigned char conv) {
    fclass f = kairo_rt_fmt_decode_ieee_(0, bits, 3, 4, 1);
    return kairo_rt_fmt_format_float_(out, cap, &f, bits, 0, 3, prec, conv);
}

int kairo_rt_fmt_f8e5m2(unsigned char *out, size_t cap, uint8_t bits, int prec, unsigned char conv) {
    fclass f = kairo_rt_fmt_decode_ieee_(0, bits, 2, 5, 0);
    return kairo_rt_fmt_format_float_(out, cap, &f, bits, 0, 2, prec, conv);
}

int kairo_rt_fmt_f32(unsigned char *out, size_t cap, float v, int prec, unsigned char conv) {
    uint32_t bits;
    fclass   f;
    memcpy(&bits, &v, sizeof bits);
    if (prec < 0 && ((bits >> 23) & 0xFF) != 0xFF && (bits << 1) != 0) {
        return kairo_rt_fmt_write_shortest_(out, cap, kairo_rt_fmt_db32_to_decimal_(bits), conv, 9);
    }
    f = kairo_rt_fmt_decode_ieee_(0, bits, 23, 8, 0);
    return kairo_rt_fmt_format_float_(out, cap, &f, bits, 32, 9, prec, conv);
}

int kairo_rt_fmt_f64(unsigned char *out, size_t cap, double v, int prec, unsigned char conv) {
    uint64_t bits;
    fclass   f;
    memcpy(&bits, &v, sizeof bits);
    if (prec < 0 && ((bits >> 52) & 0x7FF) != 0x7FF && (bits << 1) != 0) {
        return kairo_rt_fmt_write_shortest_(out, cap, kairo_rt_fmt_db64_to_decimal_(bits), conv, 17);
    }
    f = kairo_rt_fmt_decode_ieee_(0, bits, 52, 11, 0);
    return kairo_rt_fmt_format_float_(out, cap, &f, bits, 64, 17, prec, conv);
}

int kairo_rt_fmt_f128(unsigned char *out, size_t cap, uint64_t hi, uint64_t lo, int prec, unsigned char conv) {
    fclass f = kairo_rt_fmt_decode_ieee_(hi, lo, 112, 15, 0);
    return kairo_rt_fmt_format_float_(out, cap, &f, 0, 0, 36, prec, conv);
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
    f = kairo_rt_fmt_decode_x87_(mant, se);
    return kairo_rt_fmt_format_float_(out, cap, &f, 0, 0, 21, prec, conv);
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
