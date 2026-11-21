/// --- The Kairo Project ----------------------------- Native/Int128.k --- ///
///
///   64x64 -> 128 multiply-add primitives for literal accumulation
///   (Lexer/ImmBig.k, module Int128), on `u128` (`unsigned __int128`).
///
///   Each function is defined only under the condition ImmBig.k tests
///   before calling it (`defined(__SIZEOF_INT128__)`, when not
///   `defined(_MSC_VER)`), with the in/out operands as pointers. The
///   `_MSC_VER` path is Native/Int128.hh: it needs <intrin.h>, which exists
///   only on that target, and an ffi import is read whatever `eval if` it
///   stands in. The portable 32-bit-limb fallback is ImmBig.k's own.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub module wide {
    eval if !defined!(_MSC_VER) && defined!(__SIZEOF_INT128__) {
        /// *val = *val * factor + addend (low 64 bits); *hi = the high 64
        /// bits. Returns true when the result does not fit 64 bits.
        pub inline fn mul_add_64(val: unsafe *u64, factor: u64, addend: u64, hi: unsafe *u64) -> bool {
            const prod: u128 = (*val as u128) * (factor as u128) + (addend as u128)
            const result_lo: u64 = prod as u64
            const result_hi: u64 = (prod >> 64) as u64

            *val = result_lo
            *hi  = result_hi
            return result_hi != 0
        }

        /// (*hi:*lo) = (*hi:*lo) * factor + addend. Returns true when the
        /// result does not fit 128 bits.
        pub inline fn mul_add_128(lo: unsafe *u64, hi: unsafe *u64, factor: u64, addend: u64) -> bool {
            // The overflow test has to cover BOTH steps. Testing only
            // `val > max_safe` before the multiply misses the case where the
            // product fits exactly and the addend is what pushes it over: at
            // `val == max_safe` the product is the largest representable
            // multiple of factor, so any non-zero addend wraps. That is the
            // 2^128 boundary: the final digit of 2^128 in base 10 arrives
            // with val == max_safe and addend == 6.
            const val:        u128 = ((*hi as u128) << 64) | (*lo as u128)
            const factor_128: u128 = factor as u128
            const all_ones:   u128 = ~(0 as u128)

            // step 1: does the multiply alone overflow?
            const max_safe: u128 = all_ones / factor_128
            var   overflow: bool = val > max_safe

            // step 2: does adding the addend overflow? Checked against the
            // headroom left after the multiply rather than by inspecting the
            // sum, so it is a real test even when step 1 already wrapped.
            var prod: u128 = val * factor_128
            if prod > all_ones - (addend as u128) {
                overflow = true
            }

            prod += addend as u128
            *lo = prod as u64
            *hi = (prod >> 64) as u64
            return overflow
        }

        /// *limb = low 64 bits of *limb * factor + *carry; *carry = the high 64.
        pub inline fn mul_limb(limb: unsafe *u64, factor: u64, carry: unsafe *u64) {
            const prod: u128 = (*limb as u128) * (factor as u128) + (*carry as u128)
            *limb  = prod as u64
            *carry = (prod >> 64) as u64
        }
    }
}
