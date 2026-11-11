/// --- The Kairo Project ------------------------------- Lexer/ImmBig.k --- ///
///
///   Wide literal arithmetic: Int128, ImmBigInt and ImmBigFloat.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "Native/KInt128.hh" // kairo::wide: 64x64 -> 128 multiply-add
ffi "c++" import "bit"

/// \brief portable 128-bit arithmetic operations
/// \details uses compiler intrinsics where available, falls back to manual implementation
pub module Int128 {
    /// \brief multiplies a 64-bit value by a factor and adds addend
    /// \param val 64-bit value (in/out)
    /// \param factor 64-bit multiplier
    /// \param addend 64-bit value to add
    /// \param hi receives the high 64 bits if overflow
    /// \returns true if result overflows 64 bits
    pub inline static fn mul_add_64(@inout val: u64,
                                    factor:     u64,
                                    addend:     u64,
                                    @inout hi:  u64) -> bool {
        // The wide paths are intrinsics / unsigned __int128, which have no
        // Kairo spelling: Native/KInt128.hh, defined under the same tests.
        eval if defined!(_MSC_VER) {
            return kairo::wide::mul_add_64(&val, factor, addend, &hi)
        } else if defined!(__SIZEOF_INT128__) {
            return kairo::wide::mul_add_64(unsafe &val, factor, addend, unsafe &hi)
        } else {
            // manual 32-bit multiplication fallback
            var a0: u64 = val & U32_MAX
            var a1: u64 = val >> 32
            var b0: u64 = factor & U32_MAX
            var b1: u64 = factor >> 32

            var p00: u64 = a0 * b0
            var p01: u64 = a0 * b1
            var p10: u64 = a1 * b0
            var p11: u64 = a1 * b1

            var r0: u64 = p00 & U32_MAX
            var c:  u64 = p00 >> 32

            c += (p01 & U32_MAX) + (p10 & U32_MAX)
            var r1: u64 = c & U32_MAX
            c >>= 32

            c += (p01 >> 32) + (p10 >> 32) + (p11 & U32_MAX)
            var r2: u64 = c & U32_MAX
            c >>= 32

            c += p11 >> 32
            var r3: u64 = c

            var new_lo: u64 = r0 | r1 << 32
            var new_hi: u64 = r2 | r3 << 32

            // add addend
            new_lo += addend
            if new_lo < addend {
                new_hi += 1
            }

            val = new_lo
            hi  = new_hi
            return new_hi != 0
        }
    }

    /// \brief multiplies a 128-bit value by a 64-bit factor and adds a 64-bit addend
    /// \param lo lower 64 bits (in/out)
    /// \param hi upper 64 bits (in/out)
    /// \param factor 64-bit multiplier
    /// \param addend 64-bit value to add
    /// \returns true if result overflows 128 bits
    pub inline static fn mul_add_128(@inout lo: u64,
                                     @inout hi: u64,
                                     factor:    u64,
                                     addend:    u64) -> bool {
        // The wide paths, and the overflow reasoning for each, are in
        // Native/KInt128.hh (intrinsics / unsigned __int128).
        eval if defined!(_MSC_VER) {
            return kairo::wide::mul_add_128(&lo, &hi, factor, addend)
        } else if defined!(__SIZEOF_INT128__) {
            return kairo::wide::mul_add_128(unsafe &lo, unsafe &hi, factor, addend)
        } else {
            // manual fallback: split into 32-bit chunks
            // 128-bit value as (a3:a2:a1:a0) where each is 32-bit
            var a0: u64 = lo & U32_MAX
            var a1: u64 = lo >> 32
            var a2: u64 = hi & U32_MAX
            var a3: u64 = hi >> 32

            var b0: u64 = factor & U32_MAX
            var b1: u64 = factor >> 32

            // partial products for lower 128 bits
            var p00: u64 = a0 * b0
            var p01: u64 = a0 * b1
            var p10: u64 = a1 * b0
            var p11: u64 = a1 * b1
            var p20: u64 = a2 * b0
            var p21: u64 = a2 * b1
            var p30: u64 = a3 * b0
            var p31: u64 = a3 * b1 // overflow indicator

            // accumulate
            var r0: u64 = p00 & U32_MAX
            var c:  u64 = p00 >> 32

            c += (p01 & U32_MAX) + (p10 & U32_MAX)
            var r1: u64 = c & U32_MAX
            c >>= 32

            c += (p01 >> 32) + (p10 >> 32) + (p11 & U32_MAX) + (p20 & U32_MAX)
            var r2: u64 = c & U32_MAX
            c >>= 32

            c += (p11 >> 32) + (p20 >> 32) + (p21 & U32_MAX) + (p30 & U32_MAX)
            var r3: u64 = c & U32_MAX
            c >>= 32

            // overflow detection
            var ov: u64 = c + (p21 >> 32) + (p30 >> 32) + p31

            // combine results
            var new_lo: u64 = r0 | r1 << 32
            var new_hi: u64 = r2 | r3 << 32

            // add addend
            var add_carry: u64 = 0
            new_lo += addend
            if new_lo < addend {
                add_carry = 1
            }

            new_hi += add_carry
            if new_hi < add_carry {
                ov += 1
            }

            lo = new_lo
            hi = new_hi
            return ov != 0
        }
    }

    /// \brief multiplies a single 64-bit limb by factor and adds carry
    /// \param limb the limb value (in/out)
    /// \param factor 64-bit multiplier
    /// \param carry carry-in value, updated to carry-out
    pub inline static fn mul_limb(@inout limb: u64, factor: u64, @inout carry: u64) {
        eval if defined!(_MSC_VER) {
            kairo::wide::mul_limb(&limb, factor, &carry)
        } else if defined!(__SIZEOF_INT128__) {
            kairo::wide::mul_limb(unsafe &limb, factor, unsafe &carry)
        } else {
            // manual multiplication
            var a0: u64 = limb & U32_MAX
            var a1: u64 = limb >> 32
            var b0: u64 = factor & U32_MAX
            var b1: u64 = factor >> 32

            var p00: u64 = a0 * b0
            var p01: u64 = a0 * b1
            var p10: u64 = a1 * b0
            var p11: u64 = a1 * b1

            var r0: u64 = p00 & U32_MAX
            var c:  u64 = p00 >> 32

            c += (p01 & U32_MAX) + (p10 & U32_MAX)
            var r1: u64 = c & U32_MAX
            c >>= 32

            c += (p01 >> 32) + (p10 >> 32) + (p11 & U32_MAX)
            var r2: u64 = c & U32_MAX
            c >>= 32

            c += p11 >> 32
            var r3: u64 = c

            var lo: u64 = r0 | r1 << 32
            var hi: u64 = r2 | r3 << 32

            // add carry
            lo += carry
            if lo < carry {
                hi += 1
            }

            limb  = lo
            carry = hi
        }
    }
}

/// \brief arbitrary precision integer for literals exceeding 128 bits
/// \details uses a limb array with least-significant limb first (little-endian)
pub class ImmBigInt {
    pub var limbs: llvm::SmallVector<u64, 2> ///< 1-2 limbs is the common case: inline, no heap.
    pub var bits:  usize
    pub var sign:  i8

    fn ImmBigInt(self) {
        self.sign = 1
        self.bits = 0
    }

    fn ImmBigInt(self, initial_bits: usize) {
        self.sign = 1
        self.bits = initial_bits
        var num_limbs = (initial_bits + 63) / 64
        for var i: usize = 0; i < num_limbs; ++i {
            self.limbs.push_back(0)
        }
    }

    /// \brief multiplies the entire ImmBigInt by a small factor and adds a value
    /// \param factor multiplier (typically the base: 2, 8, 10, 16)
    /// \param addend value to add after multiplication
    fn mul_add(self, factor: u64, addend: u64) {
        var carry: u64 = addend

        for var i: usize = 0; i < self.limbs.size(); ++i {
            Int128::mul_limb(&self.limbs[i], factor, &carry)
        }

        // extend if carry overflows
        while carry != 0 {
            self.limbs.push_back(carry)
            carry = 0
        }
    }

    /// \brief returns the minimum number of bits needed to represent this value
    pub fn bit_width(self) -> usize {
        if self.limbs.empty() {
            return 0
        }

        var top_idx = self.limbs.size() - 1
        while top_idx > 0 && self.limbs[top_idx] == 0 {
            --top_idx
        }

        if self.limbs[top_idx] == 0 {
            return 0
        }

        var top_bits: usize = 64 - (cxx::std::countl_zero(self.limbs[top_idx]) as usize)
        return top_idx * 64 + top_bits
    }

    /// \brief true when exactly one bit is set (the magnitude is a power of two).
    pub fn is_pow2(self) -> bool {
        var ones: usize = 0
        for var i: usize = 0; i < self.limbs.size(); ++i {
            ones += (cxx::std::popcount(self.limbs[i]) as usize)
        }

        return ones == 1
    }

    /// \brief extracts lower 64 bits
    fn lo64(self) -> u64 {
        if self.limbs.empty() {
            return 0
        }

        return self.limbs[0]
    }

    /// \brief extracts bits 64-127
    fn hi64(self) -> u64 {
        if self.limbs.size() < 2 {
            return 0
        }

        return self.limbs[1]
    }

    /// \brief checks if value fits in 128 bits
    fn fits_in_128(self) -> bool {
        return self.bit_width() <= 128
    }

    /// \brief resets to zero
    fn reset(self) {
        for var i: usize = 0; i < self.limbs.size(); ++i {
            self.limbs[i] = 0
        }
    }
}

/// \brief arbitrary precision float for literals exceeding native precision
/// \details stores mantissa as ImmBigInt with separate exponent
pub class ImmBigFloat {
    pub var mantissa:  ImmBigInt
    pub var precision: usize
    pub var exponent:  i64
    pub var sign:      i8
    pub var is_hex:    bool

    fn ImmBigFloat(self) {
        self.sign      = 1
        self.exponent  = 0
        self.precision = 64
        self.is_hex    = false
    }
}
