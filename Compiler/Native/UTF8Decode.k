/// --- The Kairo Project -------------------------- Native/UTF8Decode.k --- ///
///
///   UTF-8 decoding for the lexer: length table, SIMD ASCII skip, decoder.
///
///   FIXME: make skip_ascii_simd more portable by adding fallback and full
///          support for AVX2, AVX512, etc...
///
///   Fast UTF-8 decoding utilities for compiler hot paths, used for
///   tokenization, source indexing, and diagnostics:
///     - a precomputed lookup table for UTF-8 sequence lengths
///       (`Utf8LengthTable`)
///     - SIMD ASCII scanning for fast linear skipping
///     - scalar decoding with proper UTF-8 validation
///
///   The implementation favors performance and predictability over strict
///   Unicode conformance; malformed sequences return the replacement
///   character 0xFFFD.
///
///   The SIMD routines are specialized for x86 (SSE2) and ARM (NEON) and
///   degrade to scalar behavior on other targets. `_x86_64_simd` and
///   `_aarch64_simd` are Native/Types.hh's target macros.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // _x86_64_simd / _aarch64_simd, the intrinsic headers
ffi "c++" import "Native/Shims.hh" // neon_ld_u8: vld1q_u8 is a macro
ffi "c++" import "cstring"

/// The result of decoding a single UTF-8 sequence: the decoded code point
/// (`chr`) and the number of bytes consumed (`len`). If the input sequence
/// is invalid, `chr` is the replacement character (0xFFFD) and `len` may be
/// 1.
///
/// `ok` is the only reliable validity test: a literal U+FFFD in the source
/// (EF BF BD) decodes to the same `chr` as an error, so testing `chr` for
/// 0xFFFD would reject valid input.
pub struct DecodeResult {
    pub var chr: char ///< decoded codepoint or 0xFFFD on error.
    pub var len: u8   ///< number of bytes consumed from input.
    pub var ok:  bool ///< true iff `chr` was decoded from a well-formed sequence.
}

/// Lookup table for UTF-8 byte sequence lengths, for all 256 byte values:
/// how many bytes a character beginning with that leading byte occupies. 0
/// marks a byte that can never lead a well-formed sequence (C0, C1,
/// F5..FF). Aligned to 64 bytes for cache friendliness.
@align(64) pub eval Utf8LengthTable: [u8; 256] = [
    // 0x00-0x7F: ASCII (1-byte)
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 0x80-0xBF: continuation bytes (invalid starts; decode rejects them
    // before the table is read)
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 0xC0-0xDF: 2-byte sequences; C0/C1 can only start an overlong
    // encoding, so they are 0 (never a valid lead) like the other invalids.
    0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    // 0xE0-0xEF: 3-byte sequences
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    // 0xF0-0xF4: 4-byte sequences; F5-FF would encode past U+10FFFF (or
    // are not lead bytes at all) and are 0.
    4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]

/// Skips over consecutive ASCII bytes using SIMD: scans the buffer for the
/// first non-ASCII byte (>= 0x80) using vectorized bitmask operations.
/// Optimized for bulk ASCII text in source files.
///
/// Returns a pointer to the first non-ASCII byte, or `end` if none is found
/// within the last whole 16-byte stride.
pub inline fn skip_ascii_simd(p: unsafe *const u8, end: unsafe *const u8) -> unsafe *const u8 {
    var unsafe *q = p
    eval if defined!(_x86_64_simd) {
        while end - q >= 16 {
            var v: __m128i = _mm_loadu_si128(
                unsafe (q as unsafe *const __m128i),
            )

            if _mm_movemask_epi8(v) != 0 {
                break
            }

            q += 16
        }
    } else eval if defined!(_aarch64_simd) {
        const mask: uint8x16_t = vdupq_n_u8(0x80)
        while end - q >= 16 {
            var v:    uint8x16_t = kairo::neon_ld_u8(q)
            var high: uint8x16_t = vandq_u8(v, mask)

            if vmaxvq_u8(high) != 0 {
                break
            }

            q += 16
        }
    }

    return q
}

/// The first NUL byte in [p, end), or `end` when there is none.
pub inline fn find_nul(p: unsafe *const u8, end: unsafe *const u8) -> unsafe *const u8 {
    if p >= end {
        return end
    }

    const hit = cxx::std::memchr(p, 0, (end - p) as usize)
    return if hit != &null => unsafe (hit as unsafe *const u8) else => end
}

/// Decodes a UTF-8 sequence using a lookup table.
///
/// Performs minimal validation and returns the replacement character on
/// errors: overlong sequences, invalid continuations, and surrogate code
/// points are rejected.
///
/// `s` points at the UTF-8 byte sequence, `remaining` is the number of bytes
/// left in the buffer.
pub inline fn decode_utf8_lut(s: unsafe *const u8, remaining: usize) -> DecodeResult {
    if remaining == 0 {
        return DecodeResult { chr: 0xFFFD as char, len: 0, ok: false }
    }

    const b0: u8 = s[0]

    // ASCII fast path
    if b0 < 0x80 {
        return DecodeResult { chr: b0 as char, len: 1, ok: true }
    }

    // Invalid continuation byte as start
    if b0 < 0xC0 {
        return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
    }

    const len: u8 = Utf8LengthTable[b0]

    if remaining < (len as usize) {
        return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
    }

    var cp: u32 = 0

    match len {
        case 2 {
            const b1: u32 = s[1] as u32

            if (b1 & 0xC0) != 0x80 {
                return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
            }

            cp = (((b0 as u32) & 0x1F) << 6) | (b1 & 0x3F)
            if cp < 0x80 {
                return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
            }
        } case 3 {
            const b1: u32 = s[1] as u32
            const b2: u32 = s[2] as u32

            if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 {
                return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
            }

            cp = (((b0 as u32) & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
            if cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF) {
                return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
            }
        } case 4 {
            const b1: u32 = s[1] as u32
            const b2: u32 = s[2] as u32
            const b3: u32 = s[3] as u32

            if (b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 {
                return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
            }

            cp = (((b0 as u32) & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
            if cp < 0x10000 || cp > 0x10FFFF {
                return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
            }
        } case _ {
            return DecodeResult { chr: 0xFFFD as char, len: 1, ok: false }
        }
    }

    return DecodeResult { chr: cp as char, len: len, ok: true }
}
