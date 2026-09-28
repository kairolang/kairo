/* --- The Kairo Project ------------------------------ Lib/rt/fmt.h --- */
/*
 *   The C behind Lib/builtin/fmt.k: the heap, and float text. Both live
 *   here so the builtin imports no variadic and no libc name it might
 *   collide with. Float text is Dragonbox for f32/f64 and an exact bignum
 *   printer for everything else; no libc formatting is involved anywhere,
 *   so no locale is either.
 *
 *   There is one entry per format, never a widened long double: shortest
 *   round-trip digits are a property of the SOURCE format. 0.1f is exactly
 *   0.100000001490116119384765625; as an f32 its shortest text is 0.1, as
 *   an f64 it is 0.10000000149011612. Widening erases which one was meant.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_FMT_H
#define KAIRO_RT_FMT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

unsigned char *kairo_rt_fmt_alloc(size_t n);
unsigned char *kairo_rt_fmt_realloc(unsigned char *p, size_t n);
void           kairo_rt_fmt_free(unsigned char *p);

/* |v| as text into out[0..cap): the sign bit is ignored, the caller owns
 * the sign. No NUL. Returns the bytes written, at most cap.
 *
 *   conv  'g' | 'e' | 'E', C's layouts: 'e' is d[.ddd]e+XX with a signed
 *         exponent of at least two digits; 'g' is fixed notation unless the
 *         decimal exponent is < -4 or >= P, and drops trailing zeros. inf
 *         and nan spell as C spells them for that conv.
 *
 *   prec  < 0   the shortest digits that read back as the same value in
 *               the SAME format (Dragonbox for f32/f64, exact for the
 *               rest), the closest such when several are shortest, ties to
 *               the even digit. P is the format's round-trip digit count:
 *               f8 3/2, bf16 4, f16 5, f32 9, f64 17, f80 21, f128 36.
 *         >= 0  C printf semantics at that precision: prec digits after the
 *               point for 'e', prec significant digits for 'g' (0 reads as
 *               1); every digit exact, the last correctly rounded to even.
 *
 * f16/bf16/f8 take the bit pattern because C has no portable spelling for
 * the type. f128 takes the pattern as two halves, lo being bits 0..63.
 * f80 takes long double: x87 extended on x86, and whatever long double is
 * on a target without one (binary64 or binary128), so the symbol always
 * links; TypeResolution has already refused `f80` there anyway.
 */
int kairo_rt_fmt_f16   (unsigned char *out, size_t cap, uint16_t    bits, int prec, unsigned char conv);
int kairo_rt_fmt_bf16  (unsigned char *out, size_t cap, uint16_t    bits, int prec, unsigned char conv);
int kairo_rt_fmt_f8e4m3(unsigned char *out, size_t cap, uint8_t     bits, int prec, unsigned char conv);
int kairo_rt_fmt_f8e5m2(unsigned char *out, size_t cap, uint8_t     bits, int prec, unsigned char conv);
int kairo_rt_fmt_f32   (unsigned char *out, size_t cap, float       v,    int prec, unsigned char conv);
int kairo_rt_fmt_f64   (unsigned char *out, size_t cap, double      v,    int prec, unsigned char conv);
int kairo_rt_fmt_f80   (unsigned char *out, size_t cap, long double v,    int prec, unsigned char conv);
int kairo_rt_fmt_f128  (unsigned char *out, size_t cap, uint64_t hi, uint64_t lo, int prec, unsigned char conv);

#ifdef __cplusplus
}
#endif

#endif
