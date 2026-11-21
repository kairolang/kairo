/// --- The Kairo Project ---------------------------- Native/Int128.hh --- ///
///
///   64x64 -> 128 multiply-add primitives for literal accumulation
///   (Lexer/ImmBig.k, module Int128).
///
///   WHY C++: this is the `_MSC_VER` path, MSVC's _umul128 / _addcarry_u64
///   intrinsics. They are declared by <intrin.h>, which exists only on that
///   target, and an ffi import is read whatever `eval if` it stands in, so
///   the include stays behind this header's own guard. The
///   `__SIZEOF_INT128__` path is Native/Int128.k (u128); the portable
///   32-bit-limb fallback is ImmBig.k's own.
///
///   Each function is defined only under the condition ImmBig.k tests
///   before calling it (`defined(_MSC_VER)`), with the in/out operands as
///   pointers.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KINT128_HH__
#define __KAIRO_NATIVE_KINT128_HH__

#include "Prelude.hh"

#if defined(_MSC_VER)
#include <intrin.h>
#endif

namespace kairo::wide {

#if defined(_MSC_VER)

/// *val = *val * factor + addend (low 64 bits); *hi = the high 64 bits.
/// Returns true when the result does not fit 64 bits.
inline bool mul_add_64(u64 *val, u64 factor, u64 addend, u64 *hi) {
    u64 result_hi;
    u64 result_lo = _umul128(*val, factor, &result_hi);
    unsigned char carry = _addcarry_u64(0, result_lo, addend, &result_lo);
    _addcarry_u64(carry, result_hi, 0, &result_hi);

    *val = result_lo;
    *hi  = result_hi;
    return result_hi != 0;
}

/// (*hi:*lo) = (*hi:*lo) * factor + addend. Returns true when the result
/// does not fit 128 bits.
inline bool mul_add_128(u64 *lo, u64 *hi, u64 factor, u64 addend) {
    u64 mul_lo;
    u64 mul_hi;

    // step 1: multiply lo * factor -> 128-bit result
    mul_lo = _umul128(*lo, factor, &mul_hi);

    // step 2: add addend to mul_lo, propagate carry
    unsigned char carry = _addcarry_u64(0, mul_lo, addend, &mul_lo);

    // step 3: propagate carry to mul_hi. The carry OUT of this add is kept in
    // its own variable: step 5 overwrites `carry`, and a carry out of mul_hi
    // is an overflow. Unreachable for the only caller (digit accumulation
    // passes factor <= 16, which bounds mul_hi at 15), but the signature
    // accepts any u64 factor.
    unsigned char addend_carry = _addcarry_u64(carry, mul_hi, 0, &mul_hi);

    // step 4: multiply hi * factor
    u64 hi_mul_hi;
    u64 hi_mul_lo = _umul128(*hi, factor, &hi_mul_hi);

    // step 5: add hi_mul_lo to mul_hi. Three ways to leave 128 bits: the
    // addend carried out of the high limb (step 3), this add carried out, or
    // hi * factor did not fit 64 bits to begin with.
    carry = _addcarry_u64(0, mul_hi, hi_mul_lo, &mul_hi);
    bool overflow = (carry != 0) || (hi_mul_hi != 0) || (addend_carry != 0);

    *lo = mul_lo;
    *hi = mul_hi;
    return overflow;
}

/// *limb = low 64 bits of *limb * factor + *carry; *carry = the high 64.
inline void mul_limb(u64 *limb, u64 factor, u64 *carry) {
    u64 prod_hi;
    u64 prod_lo = _umul128(*limb, factor, &prod_hi);
    unsigned char c = _addcarry_u64(0, prod_lo, *carry, &prod_lo);
    _addcarry_u64(c, prod_hi, 0, &prod_hi);

    *limb  = prod_lo;
    *carry = prod_hi;
}

#endif

}  // namespace kairo::wide

#endif  // __KAIRO_NATIVE_KINT128_HH__
