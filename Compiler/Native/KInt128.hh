/// --- The Kairo Project ---------------------------- Native/KInt128.hh --- ///
///
///   64x64 -> 128 multiply-add primitives for literal accumulation
///   (Lexer/Immediate.k, module Int128).
///
///   WHY C++: the fast paths are MSVC's _umul128 / _addcarry_u64 intrinsics
///   and the GCC/Clang `unsigned __int128` type, neither of which has a
///   Kairo spelling. They used to be inline C++ bodies inside
///   Immediate.k; Stage 1 does not emit inline foreign code. The portable
///   32-bit-limb fallback has no such need and stays in Kairo.
///
///   Each function is defined only under the condition Immediate.k tests
///   before calling it (`defined(_MSC_VER)`, else
///   `defined(__SIZEOF_INT128__)`), with the in/out operands as pointers.
///   The bodies are the former inline blocks unchanged.
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

#include "KPrelude.hh"

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
    // its own variable: reusing `carry`, which step 5 overwrites, silently
    // discarded a carry out of mul_hi. Unreachable for the only caller (digit
    // accumulation passes factor <= 16, which bounds mul_hi at 15), but the
    // signature accepts any u64 factor.
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

#elif defined(__SIZEOF_INT128__)

inline bool mul_add_64(u64 *val, u64 factor, u64 addend, u64 *hi) {
    unsigned __int128 prod = (unsigned __int128)*val * factor + addend;
    u64 result_lo = (u64)prod;
    u64 result_hi = (u64)(prod >> 64);

    *val = result_lo;
    *hi  = result_hi;
    return result_hi != 0;
}

inline bool mul_add_128(u64 *lo, u64 *hi, u64 factor, u64 addend) {
    // The overflow test has to cover BOTH steps. Testing only
    // `val > max_safe` before the multiply misses the case where the
    // product fits exactly and the addend is what pushes it over: at
    // `val == max_safe` the product is the largest representable multiple of
    // factor, so any non-zero addend wraps. That is the 2^128 boundary: the
    // final digit of 2^128 in base 10 arrives with val == max_safe and
    // addend == 6, and the literal became 0.
    unsigned __int128 val        = ((unsigned __int128)*hi << 64) | *lo;
    unsigned __int128 factor_128 = (unsigned __int128)factor;
    unsigned __int128 all_ones   = ~(unsigned __int128)0;

    // step 1: does the multiply alone overflow?
    unsigned __int128 max_safe = all_ones / factor_128;
    bool overflow = (val > max_safe);

    // step 2: does adding the addend overflow? Checked against the headroom
    // left after the multiply rather than by inspecting the sum, so it is a
    // real test even when step 1 already wrapped.
    unsigned __int128 prod = val * factor_128;
    if (prod > all_ones - (unsigned __int128)addend) {
        overflow = true;
    }

    prod += (unsigned __int128)addend;
    *lo = (u64)prod;
    *hi = (u64)(prod >> 64);
    return overflow;
}

inline void mul_limb(u64 *limb, u64 factor, u64 *carry) {
    unsigned __int128 prod = (unsigned __int128)*limb * factor + *carry;
    *limb  = (u64)prod;
    *carry = (u64)(prod >> 64);
}

#endif

}  // namespace kairo::wide

#endif  // __KAIRO_NATIVE_KINT128_HH__
