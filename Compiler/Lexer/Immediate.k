/// --- The Kairo Project ---------------------------- Lexer/Immediate.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Location::SourceRange::*;
import Location::SourceManager::*;
import Token::TokenBuffer::*;
import Memory::ArenaList::*;
import Support::EvalHash::*;

/// TODO: change suffixes to Tokens itself rather then SourceRange since we
///       don't want to reparse and a Token is smaller (32 bytes vs 64 bytes)

/// \brief portable 128-bit arithmetic operations
/// \details uses compiler intrinsics where available, falls back to manual implementation
module Int128 {
    /// \brief multiplies a 64-bit value by a factor and adds addend
    /// \param val 64-bit value (in/out)
    /// \param factor 64-bit multiplier
    /// \param addend 64-bit value to add
    /// \param hi receives the high 64 bits if overflow
    /// \returns true if result overflows 64 bits
    inline static fn mul_add_64(val: ref!(u64), factor: u64, addend: u64, hi: ref!(u64)) -> bool {
        const eval if defined(_MSC_VER) {
            var result_hi: u64;
            var result_lo: u64;
            var carry: u8;

            __inline_cpp("
                result_lo = _umul128(val, factor, &result_hi);
                carry = _addcarry_u64(0, result_lo, addend, &result_lo);
                _addcarry_u64(carry, result_hi, 0, &result_hi);
            ");

            val = result_lo;
            hi = result_hi;
            return result_hi != 0;

        } else if defined(__SIZEOF_INT128__) {
            var result_lo: u64;
            var result_hi: u64;

            __inline_cpp("
                unsigned __int128 prod = (unsigned __int128)val * factor + addend;
                result_lo = (uint64_t)prod;
                result_hi = (uint64_t)(prod >> 64);
            ");

            val = result_lo;
            hi = result_hi;
            return result_hi != 0;

        } else {
            // manual 32-bit multiplication fallback
            var a0: u64 = val & 0xFFFFFFFF;
            var a1: u64 = val >> 32;
            var b0: u64 = factor & 0xFFFFFFFF;
            var b1: u64 = factor >> 32;

            var p00: u64 = a0 * b0;
            var p01: u64 = a0 * b1;
            var p10: u64 = a1 * b0;
            var p11: u64 = a1 * b1;

            var r0: u64 = p00 & 0xFFFFFFFF;
            var c:  u64 = p00 >> 32;

            c += (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF);
            var r1: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            c += (p01 >> 32) + (p10 >> 32) + (p11 & 0xFFFFFFFF);
            var r2: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            c += (p11 >> 32);
            var r3: u64 = c;

            var new_lo: u64 = r0 | (r1 << 32);
            var new_hi: u64 = r2 | (r3 << 32);

            // add addend
            new_lo += addend;
            if new_lo < addend {
                new_hi += 1;
            }

            val = new_lo;
            hi = new_hi;
            return new_hi != 0;
        }
    }

    /// \brief multiplies a 128-bit value by a 64-bit factor and adds a 64-bit addend
    /// \param lo lower 64 bits (in/out)
    /// \param hi upper 64 bits (in/out)
    /// \param factor 64-bit multiplier
    /// \param addend 64-bit value to add
    /// \returns true if result overflows 128 bits
    inline static fn mul_add_128(lo: ref!(u64), hi: ref!(u64), factor: u64, addend: u64) -> bool {
        const eval if defined(_MSC_VER) {
            var mul_lo: u64;
            var mul_hi: u64;
            var carry: u8;

            // step 1: multiply lo * factor -> 128-bit result
            __inline_cpp("
                mul_lo = _umul128(lo, factor, &mul_hi);
            ");

            // step 2: add addend to mul_lo, propagate carry
            __inline_cpp("
                carry = _addcarry_u64(0, mul_lo, addend, &mul_lo);
            ");

            // step 3: propagate carry to mul_hi
            __inline_cpp("
                carry = _addcarry_u64(carry, mul_hi, 0, &mul_hi);
            ");

            // step 4: multiply hi * factor
            var hi_mul_lo: u64;
            var hi_mul_hi: u64;

            __inline_cpp("
                hi_mul_lo = _umul128(hi, factor, &hi_mul_hi);
            ");

            // step 5: add hi_mul_lo to mul_hi, check overflow
            var overflow: bool;
            __inline_cpp("
                carry = _addcarry_u64(0, mul_hi, hi_mul_lo, &mul_hi);
                overflow = (carry != 0) || (hi_mul_hi != 0);
            ");

            lo = mul_lo;
            hi = mul_hi;
            return overflow;

        } else if defined(__SIZEOF_INT128__) {
            var result_lo: u64;
            var result_hi: u64;
            var overflow: bool;

            __inline_cpp("
                unsigned __int128 val = ((unsigned __int128)hi << 64) | lo;
                unsigned __int128 factor_128 = (unsigned __int128)factor;
                
                // check for overflow before multiply
                unsigned __int128 max_safe = ~(unsigned __int128)0 / factor_128;
                overflow = (val > max_safe);
                
                unsigned __int128 prod = val * factor_128 + (unsigned __int128)addend;
                result_lo = (uint64_t)prod;
                result_hi = (uint64_t)(prod >> 64);
            ");

            lo = result_lo;
            hi = result_hi;
            return overflow;

        } else {
            // manual fallback: split into 32-bit chunks
            // 128-bit value as (a3:a2:a1:a0) where each is 32-bit
            var a0: u64 = lo & 0xFFFFFFFF;
            var a1: u64 = lo >> 32;
            var a2: u64 = hi & 0xFFFFFFFF;
            var a3: u64 = hi >> 32;

            var b0: u64 = factor & 0xFFFFFFFF;
            var b1: u64 = factor >> 32;

            // partial products for lower 128 bits
            var p00: u64 = a0 * b0;
            var p01: u64 = a0 * b1;
            var p10: u64 = a1 * b0;
            var p11: u64 = a1 * b1;
            var p20: u64 = a2 * b0;
            var p21: u64 = a2 * b1;
            var p30: u64 = a3 * b0;
            var p31: u64 = a3 * b1; // overflow indicator

            // accumulate
            var r0: u64 = p00 & 0xFFFFFFFF;
            var c:  u64 = p00 >> 32;

            c += (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF);
            var r1: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            c += (p01 >> 32) + (p10 >> 32) + (p11 & 0xFFFFFFFF) + (p20 & 0xFFFFFFFF);
            var r2: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            c += (p11 >> 32) + (p20 >> 32) + (p21 & 0xFFFFFFFF) + (p30 & 0xFFFFFFFF);
            var r3: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            // overflow detection
            var ov: u64 = c + (p21 >> 32) + (p30 >> 32) + p31;

            // combine results
            var new_lo: u64 = r0 | (r1 << 32);
            var new_hi: u64 = r2 | (r3 << 32);

            // add addend
            var add_carry: u64 = 0;
            new_lo += addend;
            if new_lo < addend {
                add_carry = 1;
            }
            new_hi += add_carry;
            if new_hi < add_carry {
                ov += 1;
            }

            lo = new_lo;
            hi = new_hi;
            return ov != 0;
        }
    }

    /// \brief multiplies a single 64-bit limb by factor and adds carry
    /// \param limb the limb value (in/out)
    /// \param factor 64-bit multiplier
    /// \param carry carry-in value, updated to carry-out
    inline static fn mul_limb(limb: ref!(u64), factor: u64, carry: ref!(u64)) {
        const eval if defined(_MSC_VER) {
            var prod_hi: u64;
            var prod_lo: u64;

            __inline_cpp("
                prod_lo = _umul128(limb, factor, &prod_hi);
                unsigned char c = _addcarry_u64(0, prod_lo, carry, &prod_lo);
                _addcarry_u64(c, prod_hi, 0, &prod_hi);
            ");

            limb = prod_lo;
            carry = prod_hi;

        } else if defined(__SIZEOF_INT128__) {
            var new_limb: u64;
            var new_carry: u64;

            __inline_cpp("
                unsigned __int128 prod = (unsigned __int128)limb * factor + carry;
                new_limb = (uint64_t)prod;
                new_carry = (uint64_t)(prod >> 64);
            ");

            limb = new_limb;
            carry = new_carry;

        } else {
            // manual multiplication
            var a0: u64 = limb & 0xFFFFFFFF;
            var a1: u64 = limb >> 32;
            var b0: u64 = factor & 0xFFFFFFFF;
            var b1: u64 = factor >> 32;

            var p00: u64 = a0 * b0;
            var p01: u64 = a0 * b1;
            var p10: u64 = a1 * b0;
            var p11: u64 = a1 * b1;

            var r0: u64 = p00 & 0xFFFFFFFF;
            var c:  u64 = p00 >> 32;

            c += (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF);
            var r1: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            c += (p01 >> 32) + (p10 >> 32) + (p11 & 0xFFFFFFFF);
            var r2: u64 = c & 0xFFFFFFFF;
            c >>= 32;

            c += (p11 >> 32);
            var r3: u64 = c;

            var lo: u64 = r0 | (r1 << 32);
            var hi: u64 = r2 | (r3 << 32);

            // add carry
            lo += carry;
            if lo < carry {
                hi += 1;
            }

            limb = lo;
            carry = hi;
        }
    }
}

/// \brief arbitrary precision integer for literals exceeding 128 bits
/// \details uses a limb array with least-significant limb first (little-endian)
class BigInt {
    pub var limbs: libcxx::deque::<u64>;
    pub var bits:  usize;
    pub var sign:  i8;

    fn BigInt(self) {
        self.sign = 1;
        self.bits = 0;
    }

    fn BigInt(self, initial_bits: usize) {
        self.sign = 1;
        self.bits = initial_bits;
        var num_limbs = (initial_bits + 63) / 64;
        for var i: usize = 0; i < num_limbs; ++i {
            self.limbs.push_back(0);
        }
    }

    /// \brief multiplies the entire BigInt by a small factor and adds a value
    /// \param factor multiplier (typically the base: 2, 8, 10, 16)
    /// \param addend value to add after multiplication
    fn mul_add(self, factor: u64, addend: u64) {
        var carry: u64 = addend;

        for var i: usize = 0; i < self.limbs.size(); ++i {
            Int128::mul_limb(self.limbs[i], factor, carry);
        }

        // extend if carry overflows
        while carry != 0 {
            self.limbs.push_back(carry);
            carry = 0;
        }
    }

    /// \brief returns the minimum number of bits needed to represent this value
    fn bit_width(self) -> usize {
        if self.limbs.empty() {
            return 0;
        }

        var top_idx = self.limbs.size() - 1;
        while top_idx > 0 && self.limbs[top_idx] == 0 {
            --top_idx;
        }

        if self.limbs[top_idx] == 0 {
            return 0;
        }

        var top_bits: usize = 64 - static_cast::<usize>(libcxx::countl_zero(self.limbs[top_idx]));
        return top_idx * 64 + top_bits;
    }

    /// \brief extracts lower 64 bits
    fn lo64(self) -> u64 {
        if self.limbs.empty() { return 0; }
        return self.limbs[0];
    }

    /// \brief extracts bits 64-127
    fn hi64(self) -> u64 {
        if self.limbs.size() < 2 { return 0; }
        return self.limbs[1];
    }

    /// \brief checks if value fits in 128 bits
    fn fits_in_128(self) -> bool {
        return self.bit_width() <= 128;
    }

    /// \brief resets to zero
    fn reset(self) {
        for var i: usize = 0; i < self.limbs.size(); ++i {
            self.limbs[i] = 0;
        }
    }
}

/// \brief arbitrary precision float for literals exceeding native precision
/// \details stores mantissa as BigInt with separate exponent
class BigFloat {
    pub var mantissa:  BigInt;
    pub var precision: usize;
    pub var exponent:  i64;
    pub var sign:      i8;
    pub var is_hex:    bool;

    fn BigFloat(self) {
        self.sign      = 1;
        self.exponent  = 0;
        self.precision = 64;
        self.is_hex    = false;
    }
}

module Immediate {
    static var DIGIT_TABLE: array::<u8, 128> = __inline_cpp("{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 0-7
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 8-15
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 16-23
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 24-31
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 32-39
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 40-47
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // 48-55 ('0'-'7')
        0x08, 0x09, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 56-63 ('8'-'9')
        0xFF, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, // 64-71 ('@', 'A'-'G')
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, // 72-79 ('H'-'O')
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, // 80-87 ('P'-'W')
        0x21, 0x22, 0x23, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 88-95 ('X'-'Z', '['-'_')
        0xFF, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, // 96-103 ('`', 'a'-'g')
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, // 104-111 ('h'-'o')
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, // 112-119 ('p'-'w')
        0x21, 0x22, 0x23, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  // 120-127 ('x'-'z', '{'-DEL)
    }");

    /// \brief fast digit lookup with base validation
    /// \param c character to look up
    /// \param base numeric base (2, 8, 10, 16)
    /// \returns digit value or 0xFF if invalid
    inline static fn get_digit_value(c: char, base: u8) -> u8 {
        if c >= 128 { return 0xFF; }
        var val = DIGIT_TABLE[static_cast::<usize>(c)];
        if val >= base { return 0xFF; }
        return val;
    }

    /// \brief determines bit width and signedness from integer suffix
    /// \param suffix the suffix text (e.g., "u64", "i32")
    /// \param is_unsigned output: set to true if unsigned suffix
    /// \returns bit width, or 0 if no valid suffix
    static fn parse_int_suffix(suffix: string, is_unsigned: ref!(bool)) -> u16 {
        var len = suffix.length();
        if len == 0 { return 0; }

        var data = suffix.raw();
        var idx: usize = 0;

        is_unsigned = false;

        // check for u/i prefix
        if data[0] == 'u' || data[0] == 'U' {
            is_unsigned = true;
            idx = 1;
        } else if data[0] == 'i' || data[0] == 'I' {
            is_unsigned = false;
            idx = 1;
        } else {
            return 0;
        }

        if idx >= len { return 0; }

        // parse the number part
        var bits: u64 = 0;
        while idx < len {
            var c = data[idx];
            if c < '0' || c > '9' { return 0; }
            bits = bits * 10 + static_cast::<u64>(c - '0');
            if bits > 65535 { return 0; }
            ++idx;
        }

        return static_cast::<u16>(bits);
    }

    /// \brief determines bit width from float suffix
    /// \param suffix the suffix text (e.g., "f32", "f64", "f128")
    /// \returns bit width, or 0 if no valid suffix
    static fn parse_float_suffix(suffix: string) -> u32 {
        var len = suffix.length();
        if len == 0 { return 0; }

        var data = suffix.raw();

        // must start with 'f' or 'F'
        if data[0] != 'f' && data[0] != 'F' { return 0; }
        if len == 1 { return 0; }

        // parse the number part
        var bits: u64 = 0;
        for var idx: usize = 1; idx < len; ++idx {
            var c = data[idx];
            if c < '0' || c > '9' { return 0; }
            bits = bits * 10 + static_cast::<u64>(c - '0');
            if bits > 0xFFFFFFFF { return 0; }
        }

        return static_cast::<u32>(bits);
    }

    class IntData {
        pub var body:     SourceRange;
        pub var prefix:   SourceRange;
        pub var suffix:   SourceRange;

        pub var value_lo: u64;
        pub var value_hi: u64;
        pub var big:      *BigInt = &null;

        pub var bits:     u16;
        pub var base:     u8;
        pub var flags:    u8;
        // flags layout:
        //   bit 0: unsigned
        //   bit 1: negative
        //   bit 2: is_big (value >128-bit)
        //   bit 3: has_suffix
        //   bit 4: has_prefix

        priv var _evaluation_status_cb: fn (bool);

        fn IntData(self, parsing_status_cb: fn (bool)) {
            self.value_lo = 0;
            self.value_hi = 0;
            self.bits     = 0;
            self.base     = 10;
            self.flags    = 0;
            self._evaluation_status_cb = parsing_status_cb;
        }

        fn evaluate(self, sm: *SourceManager) {
            self._evaluation_status_cb(true);

            // reset values
            self.value_lo = 0;
            self.value_hi = 0;

            if self.big != &null {
                std::destroy(self.big);
                self.big = &null;
            }

            // clear is_big flag, preserve others
            self.flags &= ~(0b00000100 as u8);

            var body_text = sm->get_text(self.body);
            var body_len  = body_text.length();

            if body_len == 0 {
                self._evaluation_status_cb(false);
                return;
            }

            var data     = body_text.raw();
            var base_u64 = static_cast::<u64>(self.base);

            // phase 1: try to fit in 64 bits
            var overflow_hi: u64 = 0;
            var overflowed: bool = false;
            var idx: usize = 0;

            while idx < body_len {
                var c = data[idx];
                ++idx;

                // skip underscores
                if c == '_' { continue; }

                var digit = get_digit_value(c, self.base);
                if digit == 0xFF { continue; }

                if Int128::mul_add_64(self.value_lo, base_u64, static_cast::<u64>(digit), overflow_hi) {
                    overflowed = true;
                    break;
                }
            }

            if !overflowed {
                // fits in 64 bits
                self.value_hi = 0;
            } else {
                // phase 2: try to fit in 128 bits
                self.value_lo = 0;
                self.value_hi = 0;

                var in_128: bool = true;
                idx = 0;

                while idx < body_len {
                    var c = data[idx];
                    ++idx;

                    if c == '_' { continue; }

                    var digit = get_digit_value(c, self.base);
                    if digit == 0xFF { continue; }

                    if Int128::mul_add_128(self.value_lo, self.value_hi, base_u64, static_cast::<u64>(digit)) {
                        in_128 = false;
                        break;
                    }
                }

                if !in_128 {
                    // phase 3: use BigInt
                    self.flags |= 0b00000100; // set is_big flag

                    self.big = std::create::<BigInt>(256);
                    idx = 0;

                    while idx < body_len {
                        var c = data[idx];
                        ++idx;

                        if c == '_' { continue; }

                        var digit = get_digit_value(c, self.base);
                        if digit == 0xFF { continue; }

                        self.big->mul_add(base_u64, static_cast::<u64>(digit));
                    }

                    // copy lo/hi from BigInt for convenience
                    self.value_lo = self.big->lo64();
                    self.value_hi = self.big->hi64();
                }
            }

            // parse suffix to determine bit width and signedness
            if (self.flags & 0b00001000) != 0 { // has_suffix
                var suffix_text = sm->get_text(self.suffix);
                var is_unsigned: bool = false;
                var suffix_bits = parse_int_suffix(suffix_text, is_unsigned);

                if suffix_bits > 0 {
                    self.bits = suffix_bits;
                    if is_unsigned {
                        self.flags |= 0b00000001; // set unsigned flag
                    } else {
                        self.flags &= ~(0b00000001 as u8); // clear unsigned flag
                    }
                }
            }

            // infer minimum bit width if no suffix
            if self.bits == 0 {
                if self.big != &null {
                    var actual_bits = self.big->bit_width();
                    // round up to next power of 2
                    if actual_bits <= 128 {
                        self.bits = 128;
                    } else if actual_bits <= 256 {
                        self.bits = 256;
                    } else if actual_bits <= 512 {
                        self.bits = 512;
                    } else if actual_bits <= 1024 {
                        self.bits = 1024;
                    } else {
                        self.bits = static_cast::<u16>((actual_bits + 63) & ~63);
                    }
                } else if self.value_hi != 0 {
                    self.bits = 128;
                } else {
                    // calculate actual bit width needed for value_lo
                    if self.value_lo == 0 {
                        self.bits = 8;
                    } else {
                        var bit_width: usize = 64 - static_cast::<usize>(libcxx::countl_zero(self.value_lo));
                        
                        if bit_width <= 8 {
                            self.bits = 8;
                        } else if bit_width <= 16 {
                            self.bits = 16;
                        } else if bit_width <= 32 {
                            self.bits = 32;
                        } else {
                            self.bits = 64;
                        }
                    }
                }
            }

            self._evaluation_status_cb(false);
        }

        fn to_string(self, sm: *SourceManager) -> string {
            var body_str   = sm->get_text(self.body);
            var prefix_str = sm->get_text(self.prefix);
            var suffix_str = sm->get_text(self.suffix);

            return f"IntData(base={(self.base) as u64}, body='{body_str}', prefix='{prefix_str}', suffix='{suffix_str}', flags=0x{to_hex_string(self.flags)}, bits={self.bits}, value_lo=0x{to_hex_string(self.value_lo)}, value_hi=0x{to_hex_string(self.value_hi)})\n";
        }

        fn op delete (self) {
            if self.big != &null {
                std::destroy(self.big);
                self.big = &null;
            }
        }
    }

    class FloatData {
        pub var body:   SourceRange;
        pub var prefix: SourceRange;
        pub var suffix: SourceRange;

        pub var bits:   u32;
        pub var base:   u8;
        pub var flags:  u8;
        // flags layout:
        //   bit 0: has_exponent
        //   bit 1: negative
        //   bit 2: is_hex_float
        //   bit 3: use_bigfloat
        //   bit 4: has_suffix

        pub var value_ieee: f80 = 0.0;
        pub var big_float:  *BigFloat = &null;

        priv var _evaluation_status_cb: fn (bool);

        fn FloatData(self, parsing_status_cb: fn (bool)) {
            self.bits  = 0;
            self.base  = 10;
            self.flags = 0;
            self._evaluation_status_cb = parsing_status_cb;
        }

        fn evaluate(self, sm: *SourceManager) {
            self._evaluation_status_cb(true);

            self.value_ieee = 0.0;

            if self.big_float != &null {
                std::destroy(self.big_float);
                self.big_float = &null;
            }

            // clear use_bigfloat flag, preserve others
            self.flags &= ~(0b00001000 as u8);

            var body_text = sm->get_text(self.body);
            var body_len  = body_text.length();

            if body_len == 0 {
                self._evaluation_status_cb(false);
                return;
            }

            var data   = body_text.raw();
            var is_hex = (self.flags & 0b00000100) != 0;

            // parsing state
            var integer_part:     u64  = 0;
            var frac_numerator:   u64  = 0;
            var frac_digits:      i32  = 0;
            var exp_value:        i64  = 0;
            var exp_negative:     bool = false;
            var has_integer:      bool = false;
            var has_fraction:     bool = false;
            var integer_overflow: bool = false;
            var frac_overflow:    bool = false;

            var idx: usize = 0;
            var base_u64 = static_cast::<u64>(self.base);

            // parse integer part
            while idx < body_len {
                var c = data[idx];

                if c == '_' {
                    ++idx;
                    continue;
                }

                if c == '.' {
                    ++idx;
                    break;
                }

                // check for exponent start
                if is_hex {
                    if c == 'p' || c == 'P' { break; }
                } else {
                    if c == 'e' || c == 'E' { break; }
                }

                var digit = get_digit_value(c, self.base);
                if digit == 0xFF { break; }

                has_integer = true;

                if !integer_overflow {
                    var old = integer_part;
                    integer_part = integer_part * base_u64 + static_cast::<u64>(digit);
                    if integer_part < old {
                        integer_overflow = true;
                    }
                }

                ++idx;
            }

            // check if we just consumed a dot
            var consumed_dot = (idx > 0) && (data[idx - 1] == '.');

            // parse fractional part
            if consumed_dot {
                while idx < body_len {
                    var c = data[idx];

                    if c == '_' {
                        ++idx;
                        continue;
                    }

                    // check for exponent start
                    if is_hex {
                        if c == 'p' || c == 'P' { break; }
                    } else {
                        if c == 'e' || c == 'E' { break; }
                    }

                    var digit = get_digit_value(c, self.base);
                    if digit == 0xFF { break; }

                    has_fraction = true;

                    if !frac_overflow {
                        var old = frac_numerator;
                        frac_numerator = frac_numerator * base_u64 + static_cast::<u64>(digit);
                        if frac_numerator < old {
                            frac_overflow = true;
                        } else {
                            ++frac_digits;
                        }
                    }

                    ++idx;
                }
            }

            // parse exponent
            if idx < body_len {
                var c = data[idx];
                var is_exp_char = false;

                if is_hex {
                    is_exp_char = (c == 'p' || c == 'P');
                } else {
                    is_exp_char = (c == 'e' || c == 'E');
                }

                if is_exp_char {
                    ++idx;

                    // check for sign
                    if idx < body_len {
                        if data[idx] == '-' {
                            exp_negative = true;
                            ++idx;
                        } else if data[idx] == '+' {
                            ++idx;
                        }
                    }

                    // parse exponent digits (always base 10, but allow underscores)
                    while idx < body_len {
                        var ec = data[idx];

                        // skip underscores in exponent
                        if ec == '_' {
                            ++idx;
                            continue;
                        }

                        if ec < '0' || ec > '9' { break; }

                        exp_value = exp_value * 10 + static_cast::<i64>(ec - '0');
                        ++idx;
                    }

                    if exp_negative {
                        exp_value = -exp_value;
                    }
                }
            }

            // determine if we need BigFloat
            // thresholds: f80 max exponent is ~4932 (base 10) or ~16383 (base 2)
            var needs_big = integer_overflow || frac_overflow;

            if !needs_big {
                if is_hex {
                    needs_big = (exp_value > 16383) || (exp_value < -16494);
                } else {
                    needs_big = (exp_value > 4932) || (exp_value < -4951);
                }
            }

            if needs_big {
                self.flags |= 0b00001000; // set use_bigfloat flag
                self.big_float = std::create::<BigFloat>();
                self.big_float->is_hex = is_hex;
                self.big_float->exponent = exp_value;

                // reparse integer part into BigInt mantissa
                self.big_float->mantissa = BigInt(512);
                idx = 0;

                var frac_start: usize = 0;
                var parsing_frac: bool = false;

                while idx < body_len {
                    var c = data[idx];

                    if c == '_' {
                        ++idx;
                        continue;
                    }

                    if c == '.' {
                        ++idx;
                        frac_start = idx;
                        parsing_frac = true;
                        continue;
                    }

                    if is_hex {
                        if c == 'p' || c == 'P' { break; }
                    } else {
                        if c == 'e' || c == 'E' { break; }
                    }

                    var digit = get_digit_value(c, self.base);
                    if digit == 0xFF { break; }

                    self.big_float->mantissa.mul_add(base_u64, static_cast::<u64>(digit));

                    if parsing_frac {
                        // adjust exponent for fractional digits
                        if is_hex {
                            self.big_float->exponent -= 4; // each hex digit = 4 bits
                        } else {
                            // for decimal, we track separately and convert later
                        }
                    }

                    ++idx;
                }

                // also compute f80 approximation for convenience
                self.value_ieee = self.compute_f80_approx(
                    integer_part, frac_numerator, frac_digits,
                    exp_value, is_hex, base_u64,
                    integer_overflow, frac_overflow
                );
            } else {
                // compute f80 value directly
                self.value_ieee = self.compute_f80(
                    integer_part, frac_numerator, frac_digits,
                    exp_value, is_hex, base_u64
                );
            }

            // parse suffix
            if (self.flags & 0b00010000) != 0 { // has_suffix
                var suffix_text = sm->get_text(self.suffix);
                var suffix_bits = parse_float_suffix(suffix_text);

                if suffix_bits > 0 {
                    self.bits = suffix_bits;
                }
            }

            // default to f64 if no suffix
            if self.bits == 0 {
                self.bits = 64;
            }

            self._evaluation_status_cb(false);
        }

        /// \brief computes f80 value from parsed components
        /// \details used when value fits in extended precision
        priv fn compute_f80(
            self,
            integer_part:   u64,
            frac_numerator: u64,
            frac_digits:    i32,
            exp_value:      i64,
            is_hex:         bool,
            base:           u64
        ) -> f80 {
            var result: f80 = static_cast::<f80>(integer_part);

            // add fractional part
            if frac_digits > 0 {
                var frac: f80 = static_cast::<f80>(frac_numerator);
                var divisor: f80 = 1.0;

                for var i: i32 = 0; i < frac_digits; ++i {
                    divisor *= static_cast::<f80>(base);
                }

                result += frac / divisor;
            }

            // apply exponent
            if exp_value != 0 {
                // use ldexp for binary exponent (hex floats)
                // use pow for decimal exponent
                if is_hex {
                    // hex float: exponent is base-2
                    if exp_value > 0 {
                        for var i: i64 = 0; i < exp_value; ++i {
                            result *= 2.0;
                        }
                    } else {
                        for var i: i64 = 0; i < -exp_value; ++i {
                            result /= 2.0;
                        }
                    }
                } else {
                    // decimal: exponent is base-10
                    if exp_value > 0 {
                        for var i: i64 = 0; i < exp_value; ++i {
                            result *= 10.0;
                        }
                    } else {
                        for var i: i64 = 0; i < -exp_value; ++i {
                            result /= 10.0;
                        }
                    }
                }
            }

            return result;
        }

        /// \brief computes approximate f80 value when BigFloat is used
        /// \details provides a best-effort approximation even for huge values
        priv fn compute_f80_approx(
            self,
            integer_part:     u64,
            frac_numerator:   u64,
            frac_digits:      i32,
            exp_value:        i64,
            is_hex:           bool,
            base:             u64,
            integer_overflow: bool,
            frac_overflow:    bool
        ) -> f80 {
            // for overflowed values, we can still get a rough approximation
            // by using the last computed value and scaling

            var result: f80;

            if integer_overflow {
                // integer_part wrapped, use max u64 as approximation base
                result = static_cast::<f80>(0xFFFFFFFFFFFFFFFF);
            } else {
                result = static_cast::<f80>(integer_part);
            }

            if frac_digits > 0 && !frac_overflow {
                var frac: f80 = static_cast::<f80>(frac_numerator);
                var divisor: f80 = 1.0;

                for var i: i32 = 0; i < frac_digits; ++i {
                    divisor *= static_cast::<f80>(base);
                }

                result += frac / divisor;
            }

            // apply exponent with saturation
            if exp_value != 0 {
                var exp_base: f80 = 2.0 if is_hex else 10.0;

                // clamp to avoid infinity in intermediate calcs
                var clamped_exp = exp_value;
                if is_hex {
                    if clamped_exp > 16383 { clamped_exp = 16383; }
                    if clamped_exp < -16494 { clamped_exp = -16494; }
                } else {
                    if clamped_exp > 4932 { clamped_exp = 4932; }
                    if clamped_exp < -4951 { clamped_exp = -4951; }
                }

                if clamped_exp > 0 {
                    for var i: i64 = 0; i < clamped_exp; ++i {
                        result *= exp_base;
                    }
                } else {
                    for var i: i64 = 0; i < -clamped_exp; ++i {
                        result /= exp_base;
                    }
                }
            }

            return result;
        }

        fn to_string(self, sm: *SourceManager) -> string {
            var body_str   = sm->get_text(self.body);
            var prefix_str = sm->get_text(self.prefix);
            var suffix_str = sm->get_text(self.suffix);

            return f"FloatData(base={(self.base) as u64}, body='{body_str}', prefix='{prefix_str}', suffix='{suffix_str}', flags=0x{to_hex_string(self.flags)}, bits={self.bits}, value_ieee={self.value_ieee})\n";
        }

        fn op delete (self) {
            if self.big_float != &null {
                std::destroy(self.big_float);
                self.big_float = &null;
            }
        }
    }

    enum TextPrefixKind derives u8 {
        None   = 0,
        Format = 1 << 0,
        Raw    = 1 << 1,
        // Format
        // Bytes
        // BytesFormat
    }

    class StringData {
        /// NOTE: the TokenBuffer is allocated in the Lexer or elsewhere, but
        ///       StringData will be freeing it within its destructor.
        ///
        /// NOLINT (MA1FW) "non owner scope freeing underling memory"
        /// ^^ remember this to implement this error.
        pub var exprs: libcxx::deque::<(*TokenBuffer::<16>, SourceRange)>; // exprs tokens
                // along with the start and end from { and }

        pub var body:        SourceRange; // string range excl quotes prefix and suffix
        pub var prefix:      Token;
        pub var suffix:      Token;
        pub var next:        u32; // for chained strings, contains the next imm string idx
        pub var prefix_kind: TextPrefixKind;

        /// OWNED-TEXT representation for synthesized strings (stringify! on
        /// synthesized tokens, file!, future gensym): bytes live in
        /// ImmediateTable::synth_names (ArenaList, pointers never move).
        /// When owned_ptr is set it is the authoritative text; `body` may
        /// ADDITIONALLY be valid when the text is also a contiguous source
        /// slice (lets unstringify! re-lex without owned-text lexing support).
        pub var owned_ptr: std::ConstPtr::<u8> = &null;
        pub var owned_len: u32 = 0;

        priv var _evaluation_status_cb: fn (bool);

        fn StringData(self, parsing_status_cb: fn (bool)) {
            self._evaluation_status_cb = parsing_status_cb;
            self.next = u32(-1);
        }

        const fn has_owned_text(self) -> bool {
            return self.owned_ptr != &null;
        }

        /// basic cleanup of all internally stored pools
        fn op delete (self) {
            self.destroy();
        }

        fn destroy(self) {
            for var i: usize = 0; i < self.exprs.size(); ++i {
                std::destroy(libcxx::get::<0>(self.exprs[i]));
            }
        }
    }

    class CharData {
        pub var exprs: libcxx::deque::<(*TokenBuffer::<16>, SourceRange)>; // exprs tokens
                // along with the start and end from { and }

        pub var prefix:      Token;
        pub var suffix:      Token;
        pub var body:        SourceRange; // string range excl quotes prefix and suffix
        pub var prefix_kind: TextPrefixKind;
        pub var next:        u32; // for chained strings, contains the next imm string idx

        priv var _evaluation_status_cb: fn (bool);

        fn CharData(self, parsing_status_cb: fn (bool)) {
            self._evaluation_status_cb = parsing_status_cb;
            self.next = u32(-1);
        }

        fn op delete (self) {
            self.destroy();
        }

        fn destroy(self) {
            for var i: usize = 0; i < self.exprs.size(); ++i {
                std::destroy(libcxx::get::<0>(self.exprs[i]));
            }
        }
    }

    class MacroExpansionInfo {
        pub var invoke_range:  SourceRange;///< source range of the invocation site
        pub var def_range:     SourceRange;///< source range in the macro definition body
        pub var original_kind: TokenKind;  ///< original token kind before expansion
        pub var original_imm:  u32;        ///< original imm index (-1 if none)
        pub var parent_idx:    u32;        ///< index of parent MacroExpansionInfo (-1 = root)
        pub var macro_name:    u32;        ///< which macro produced this token
    }

    /// \brief descriptor for one interned identifier within a file (fid).
    ///
    /// \details Unlike the literal sheets (IntData/StringData/CharData/...)
    ///          which are append-only pools holding one slot per occurrence,
    ///          the identifier sheet is an *interner*: identical spellings
    ///          collapse to a single index via ImmediateTable::intern_ident.
    ///          A Token of identifier kind stores that index in its `imm` slot,
    ///          so identifier equality becomes an O(1) u32 compare within a
    ///          file.
    ///
    ///          The text itself is not stored here; it lives as raw UTF-8 in
    ///          ImmediateTable::ident_blob. This descriptor is just the
    ///          `(offset, len)` slice into that blob, which keeps lookups a pure
    ///          byte compare with no per-identifier allocation or decoding.
    class IdentData {
        pub var ptr: std::ConstPtr::<u8> = &null; ///< raw UTF-8 bytes (into source buffer or sema scratch)
        pub var len: u32 = 0;                     ///< byte length of the identifier

        fn IdentData(self) = default;
        fn IdentData(self, ptr: std::ConstPtr::<u8>, len: usize) {
            self.ptr = ptr;
            self.len = static_cast::<u32>(len);
        }
    }

    /// \brief one slot of the identifier interner's open-addressed hash table.
    ///
    /// \details 8 bytes (~8 per cache line). `idx == u32(-1)` marks an empty
    ///          slot. Collisions are resolved by linear probing; the stored
    ///          `hash` lets a probe reject non-matching entries with a single
    ///          u32 compare before ever touching the byte blob.
    class InternBucket {
        pub var hash: u32 = 0;
        pub var idx:  u32 = static_cast::<u32>(-1); ///< u32(-1) == empty slot
    }
}

class ImmediateTable {
    const MAX_IMMEDIATES: u32 = ((-1) as u32);

    var int_literals:      own::<ArenaList::<Immediate::IntData>>;
    var float_literals:    own::<ArenaList::<Immediate::FloatData>>;
    var char_literals:     own::<ArenaList::<Immediate::CharData>>;
    var string_literals:   own::<ArenaList::<Immediate::StringData>>;
    var macro_expansions:  own::<ArenaList::<Immediate::MacroExpansionInfo>>;
    var ident_descs:       own::<ArenaList::<Immediate::IdentData>>;   ///< idx -> (offset,len) into ident_blob
    var synth_names:       own::<ArenaList::<nstring>>;                ///< owned bytes for synthesized identifiers
                                                                       ///  (no backing source buffer); ArenaList
                                                                       ///  never moves, so raw() ptrs stay stable.
    var ident_buckets:     vec::<Immediate::InternBucket>;             ///< open-addressed (hash -> idx) table
    var ident_mask:        u32 = 0;                                    ///< bucket capacity - 1 (power of two); 0 = uninitialized
    var ident_live:        u32 = 0;                                    ///< number of occupied buckets (load factor)
    var source_manager:    obs::<SourceManager> = &null;
    var is_evaluating:     std::Atomic::<bool>  = false;

    fn initialize(self, sm: *SourceManager) {
        self.source_manager   = sm;
        self.int_literals     = std::create::<ArenaList::<Immediate::IntData>>(256);
        self.float_literals   = std::create::<ArenaList::<Immediate::FloatData>>(64);
        self.char_literals    = std::create::<ArenaList::<Immediate::CharData>>(64);
        self.string_literals  = std::create::<ArenaList::<Immediate::StringData>>(64);
        self.macro_expansions = std::create::<ArenaList::<Immediate::MacroExpansionInfo>>(256);
        self.ident_descs      = std::create::<ArenaList::<Immediate::IdentData>>(512);
        self.synth_names      = std::create::<ArenaList::<nstring>>(64);
        Logger::debug(Logger::Stage::Lexer, "ImmediateTable::initialize: initialized with source manager at {sm}");
    }

    fn reset(self) {
        // reset() may run before initialize() (e.g. a lexer reset before its
        // first lex)   every list is null until then. guard all of them.
        if self.int_literals     != &null { self.int_literals->clear();     }
        if self.float_literals   != &null { self.float_literals->clear();   }
        if self.char_literals    != &null { self.char_literals->clear();    }
        if self.string_literals  != &null { self.string_literals->clear();  }
        if self.macro_expansions != &null { self.macro_expansions->clear(); }
        if self.ident_descs      != &null { self.ident_descs->clear();      }
        if self.synth_names      != &null { self.synth_names->clear();      }
        self.ident_buckets.clear();
        self.ident_mask = 0;
        self.ident_live = 0;
        Logger::debug(Logger::Stage::Lexer, "ImmediateTable::reset: cleared all immediate literals and macro expansions");
    }

    fn set_parsing_status(self, is_evaluating: bool) {
        self.is_evaluating.store(is_evaluating, std::MemoryOrder::seq_cst);
    }

    fn <T> create(self) -> u32 {
        eval if __inline_cpp("std::Meta::is_same_as<T, Immediate::IntData>") {
            if (self.int_literals->size()) > MAX_IMMEDIATES {
                std::crash(std::Error::RuntimeError(
                    f"ImmediateTable::create<IntData>: overflow at {MAX_IMMEDIATES}"));
            }

            self.int_literals->push(Immediate::IntData(
                fn (s: bool) { set_parsing_status(s); }
            ));
            return static_cast::<u32>((self.int_literals->size()) - 1);

        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::FloatData>") {
            if (self.float_literals->size()) > MAX_IMMEDIATES {
                std::crash(std::Error::RuntimeError(
                    f"ImmediateTable::create<FloatData>: overflow at {MAX_IMMEDIATES}"));
            }

            self.float_literals->push(Immediate::FloatData(
                fn (s: bool) { set_parsing_status(s); }
            ));
            return static_cast::<u32>((self.float_literals->size()) - 1);

        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::CharData>") {
            if (self.char_literals->size()) > MAX_IMMEDIATES {
                std::crash(std::Error::RuntimeError(
                    f"ImmediateTable::create<CharData>: overflow at {MAX_IMMEDIATES}"));
            }

            self.char_literals->push(Immediate::CharData(
                fn (s: bool) { set_parsing_status(s); }
            ));
            return static_cast::<u32>((self.char_literals->size()) - 1);

        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::StringData>") {
            if (self.string_literals->size()) > MAX_IMMEDIATES {
                std::crash(std::Error::RuntimeError(
                    f"ImmediateTable::create<StringData>: overflow at {MAX_IMMEDIATES}"));
            }

            self.string_literals->push(Immediate::StringData(
                fn (s: bool) { set_parsing_status(s); }
            ));
            return static_cast::<u32>((self.string_literals->size()) - 1);

        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::MacroExpansionInfo>") {
            if (self.macro_expansions->size()) > MAX_IMMEDIATES {
                std::crash(std::Error::RuntimeError(
                    f"ImmediateTable::create<MacroExpansionInfo>: overflow at {MAX_IMMEDIATES}"));
            }

            self.macro_expansions->push(Immediate::MacroExpansionInfo());
            return static_cast::<u32>((self.macro_expansions->size()) - 1);

        } else {
            std::crash(std::Error::RuntimeError("ImmediateTable::create: unsupported type"));
        }
    }

    fn <T> get(self, idx: u32) -> *T {
        eval if __inline_cpp("std::Meta::is_same_as<T, Immediate::IntData>") {
            return self.int_literals->get(static_cast::<usize>(idx));
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::FloatData>") {
            return self.float_literals->get(static_cast::<usize>(idx));
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::CharData>") {
            return self.char_literals->get(static_cast::<usize>(idx));
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::StringData>") {
            return self.string_literals->get(static_cast::<usize>(idx));
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::MacroExpansionInfo>") {
            return self.macro_expansions->get(static_cast::<usize>(idx));
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::IdentData>") {
            return self.ident_descs->get(static_cast::<usize>(idx));
        } else {
            std::crash(std::Error::RuntimeError("ImmediateTable::get: unsupported type"));
        }
    }

    fn <T> pop(self) -> T {
        eval if __inline_cpp("std::Meta::is_same_as<T, Immediate::IntData>") {
            return self.int_literals->pop();
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::FloatData>") {
            return self.float_literals->pop();
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::CharData>") {
            return self.char_literals->pop();
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::StringData>") {
            return self.string_literals->pop();
        } else if __inline_cpp("std::Meta::is_same_as<T, Immediate::MacroExpansionInfo>") {
            return self.macro_expansions->pop();
        } else {
            std::crash(std::Error::RuntimeError("ImmediateTable::pop: unsupported type"));
        }
    }



    /// \brief interns an identifier from its raw UTF-8 bytes and precomputed hash.
    ///
    /// \details This is the hot path. The lexer already folds a 32-bit hash
    ///          while scanning the identifier, so it is passed in rather than
    ///          recomputed here. Lookups are allocation-free: the open-addressed
    ///          table is probed by `hash`, a single u32 compare rejects
    ///          mismatches, and only a true hash match triggers a byte compare
    ///          against the stored bytes. The identifier text is copied into the
    ///          blob exactly once, on first sight (a miss); every repeat
    ///          occurrence costs only a probe and a memcmp, never an allocation.
    ///
    ///          The returned index is stable for the table's lifetime and is
    ///          what a Token of identifier kind stores in its `imm` slot, making
    ///          identifier equality within a file an O(1) u32 compare. The unique
    ///          identifier count is bounded by the file size, so it can never
    ///          reach MAX_IMMEDIATES; that guard is defensive only.
    ///
    /// \param data raw UTF-8 bytes of the identifier (need not be NUL-terminated).
    /// \param len  byte length of the identifier.
    /// \param hash folded 32-bit hash of those bytes (caller-supplied, e.g. the
    ///             lexer's running HashState). Must be produced consistently for
    ///             a given spelling so identical identifiers collide and dedup.
    /// \return the interned index into the identifier sheet.
    fn intern_ident(self, const data: *u8, len: usize, hash: u32) -> u32 {
        if self.ident_mask == 0 {
            self._ident_grow();
        }

        var mask = self.ident_mask;
        var slot = hash & mask;

        while true {
            var b = &(self.ident_buckets[static_cast::<usize>(slot)]);
            if b->idx == ((-1) as u32) {
                break;
            }
            if (b->hash == hash) && self._ident_eq(b->idx, data, len) {
                return b->idx;
            }
            slot = (slot + 1) & mask;
        }

        if ((static_cast::<u64>(self.ident_live) + 1) * 4) >= ((static_cast::<u64>(mask) + 1) * 3) {
            self._ident_grow();
            mask = self.ident_mask;
            slot = hash & mask;
            while self.ident_buckets[static_cast::<usize>(slot)].idx != ((-1) as u32) {
                slot = (slot + 1) & mask;
            }
        }

        var idx = static_cast::<u32>(self.ident_descs->size());
        if idx >= MAX_IMMEDIATES {
            std::crash(std::Error::RuntimeError(
                f"ImmediateTable::intern_ident: overflow at {MAX_IMMEDIATES}"));
        }

        // store pointer directly no copy
        self.ident_descs->push(Immediate::IdentData(data, len));

        var nb = &(self.ident_buckets[static_cast::<usize>(slot)]);
        nb->hash = hash;
        nb->idx  = idx;
        ++self.ident_live;

        return idx;
    }

    fn get_ident(self, idx: u32) -> string {
        var d = self.ident_descs->get(static_cast::<usize>(idx));
        return string(
            reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(d->ptr),
            static_cast::<usize>(d->len)
        );
    }

    /// \brief NON-MUTATING identifier probe: index of \p data if already
    ///        interned, else \c u32(-1). Never inserts, never grows the
    ///        table safe against a FROZEN table read by other threads.
    ///
    /// \details The cross-TU import boundary (SymbolTable::lookup_foreign) uses
    ///          this: a spelling from the importing TU is probed against the
    ///          SOURCE TU's frozen imm table. A miss means the name was never
    ///          interned in the source and is therefore provably absent from
    ///          its symbol tables no insert is warranted or permitted. Mirrors
    ///          intern_ident's open-addressed probe exactly, minus every write.
    ///
    /// \param data raw UTF-8 bytes (need not be NUL-terminated).
    /// \param len  byte length.
    /// \param hash folded 32-bit hash of those bytes (same hashing as intern).
    fn find_ident(self, const data: *u8, len: usize, hash: u32) -> u32 {
        if self.ident_mask == 0 { return static_cast::<u32>(-1); }

        var mask = self.ident_mask;
        var slot = hash & mask;

        while true {
            var b = &(self.ident_buckets[static_cast::<usize>(slot)]);
            if b->idx == ((-1) as u32) { return static_cast::<u32>(-1); }
            if (b->hash == hash) && self._ident_eq(b->idx, data, len) {
                return b->idx;
            }
            slot = (slot + 1) & mask;
        }
        return static_cast::<u32>(-1);
    }

    /// \brief string-keyed convenience over find_ident (hashes for the caller).
    ///        Returns \c u32(-1) on miss. NON-MUTATING.
    ///
    /// \details `string` is wchar-backed; identifiers were interned from UTF-8
    ///          source bytes. Convert to a nstring (UTF-8) FIRST so the hash and
    ///          byte-compare match what the lexer produced this mirrors
    ///          intern_ident_copy exactly, minus the synth_names store (a probe
    ///          needs no persistent copy). Cold path (import boundary only).
    fn find_ident(self, s: string) -> u32 {
        var ns = std::string_to_nstring(s);
        var r  = reinterpret_cast::<std::ConstPtr::<u8>>(ns.raw());
        var l  = ns.size();
        var h  = compute_hash(r, l);
        return self.find_ident(r, l, h);
    }

    /// \brief interns an identifier spelling that has no backing source buffer.
    ///
    /// \details copies the bytes into table-owned storage (\c synth_names),
    ///          then interns through the normal path so synthesized and lexed
    ///          spellings of the same identifier collapse to one index.
    ///          Use for compiler-synthesized identifiers: PP builtins
    ///          (unique_id!), gensym, sema-generated names.
    ///
    /// \note hashing matches the lexer's incremental hash (compute_hash), so
    ///       a synthesized `foo` and a lexed `foo` intern to the same slot.
    fn intern_ident_copy(self, s: string) -> u32 {
        if self.synth_names == &null {
            self.synth_names = std::create::<ArenaList::<nstring>>(64);
        }
        var stored = self.synth_names->push(std::string_to_nstring(s));
        var r = reinterpret_cast::<std::ConstPtr::<u8>>(stored->raw());
        var l = stored->size();
        var h = compute_hash(r, l);
        return self.intern_ident(r, l, h);
    }

    /// \brief creates a StringData slot whose text is table-owned (no backing
    ///        source range).
    ///
    /// \details copies the bytes into \c synth_names (ArenaList never moves, so
    ///          the raw pointer stays stable for the table's lifetime). Unlike
    ///          intern_ident_copy this is NOT an interner the string sheet is
    ///          an append-only pool, one slot per occurrence, matching lexed
    ///          string literals. Use for compiler-synthesized string text:
    ///          stringify! over synthesized tokens, file!, diagnostics.
    ///
    /// \note the caller may additionally set `body` on the returned slot when
    ///       the text also happens to be a contiguous source slice.
    fn intern_string_copy(self, s: string) -> u32 {
        if self.synth_names == &null {
            self.synth_names = std::create::<ArenaList::<nstring>>(64);
        }
        var idx  = self.create::<Immediate::StringData>();
        var data = self.get::<Immediate::StringData>(idx);

        var stored = self.synth_names->push(std::string_to_nstring(s));
        data->owned_ptr   = reinterpret_cast::<std::ConstPtr::<u8>>(stored->raw());
        data->owned_len   = static_cast::<u32>(stored->size());
        data->prefix_kind = Immediate::TextPrefixKind::None;
        return idx;
    }

    /// \brief authoritative text of a string literal slot: owned bytes when
    ///        present, otherwise the source slice behind `body`.
    fn string_text(self, idx: u32, sm: *SourceManager) -> string {
        var d = self.string_literals->get(static_cast::<usize>(idx));
        if d->owned_ptr != &null {
            return string(
                reinterpret_cast::<std::ConstPtr::<std::Legacy::char>>(d->owned_ptr),
                static_cast::<usize>(d->owned_len)
            );
        }
        return sm->get_text(d->body);
    }

    fn ident_bytes(self, idx: u32) -> std::ConstPtr::<u8> {
        return self.ident_descs->get(static_cast::<usize>(idx))->ptr;
    }

    priv fn _ident_eq(self, idx: u32, const data: *u8, len: usize) -> bool {
        var d = self.ident_descs->get(static_cast::<usize>(idx));
        if static_cast::<usize>(d->len) != len {
            return false;
        }
        for var i: usize = 0; i < len; ++i {
            if d->ptr[i] != data[i] {
                return false;
            }
        }
        return true;
    }

    /// \brief byte length of an interned identifier.
    fn ident_len(self, idx: u32) -> usize {
        return static_cast::<usize>(self.ident_descs->get(static_cast::<usize>(idx))->len);
    }

    /// \brief number of unique identifiers interned for this file.
    fn ident_count(self) -> usize {
        return self.ident_descs->size();
    }

    /// \brief seeds or doubles the bucket table and rehashes the live entries.
    ///
    /// \details Buckets carry their own hash, so rehashing never re-reads
    ///          identifier bytes -- it just re-probes each occupied slot into the
    ///          larger table. Descriptor indices (the values stored in `imm`) are
    ///          unaffected; only the hash->index acceleration structure moves.
    priv fn _ident_grow(self) {
        var old_cap: u32 = 0;
        if self.ident_mask != 0 {
            old_cap = self.ident_mask + 1;
        }

        var new_cap: u32 = 256;
        if old_cap != 0 {
            new_cap = old_cap << 1;
        }
        var new_mask: u32 = new_cap - 1;

        var fresh = vec::<Immediate::InternBucket>();
        fresh.resize(static_cast::<usize>(new_cap)); // default-constructed => empty

        for var i: usize = 0; i < self.ident_buckets.size(); ++i {
            var ob = self.ident_buckets[i];
            if ob.idx == ((-1) as u32) {
                continue;
            }
            var slot = ob.hash & new_mask;
            while fresh[static_cast::<usize>(slot)].idx != ((-1) as u32) {
                slot = (slot + 1) & new_mask;
            }
            fresh[static_cast::<usize>(slot)] = ob;
        }

        self.ident_buckets = fresh;
        self.ident_mask    = new_mask;
    }

    fn destroy(self) {
        if self.int_literals != &null {
            std::destroy(self.int_literals);
            self.int_literals = &null;
        }
        if self.float_literals != &null {
            std::destroy(self.float_literals);
            self.float_literals = &null;
        }
        if self.macro_expansions != &null {
            std::destroy(self.macro_expansions);
            self.macro_expansions = &null;
        }

        if self.string_literals != &null {
            std::destroy(self.string_literals);
            self.string_literals = &null;
        }
        if self.char_literals != &null {
            std::destroy(self.char_literals);
            self.char_literals = &null;
        }
        if self.ident_descs != &null {
            std::destroy(self.ident_descs);
            self.ident_descs = &null;
        }

        if self.synth_names != &null {
            std::destroy(self.synth_names);
            self.synth_names = &null;
        }

        Logger::debug(Logger::Stage::Lexer, "ImmediateTable::destroy(): destroyed all immediate literals and macro expansions");
    }

    fn op delete (self) {
        self.destroy();
    }

    fn wait_for_evaluation(self) {
        std::sleep_while(fn () -> bool {
            return self.is_evaluating.load(std::MemoryOrder::seq_cst);
        });
    }
}