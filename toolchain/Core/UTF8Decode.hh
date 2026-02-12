///--- The Helix Project ----------------------------------------------------///
///                                                                          ///
///   Part of the Helix Project, under the Attribution 4.0 International     ///
///   license (CC BY 4.0).  You are allowed to use, modify, redistribute,    ///
///   and create derivative works, even for commercial purposes, provided    ///
///   that you give appropriate credit, and indicate if changes were made.   ///
///                                                                          ///
///   For more information on the license terms and requirements, please     ///
///     visit: https://creativecommons.org/licenses/by/4.0/                  ///
///                                                                          ///
///   SPDX-License-Identifier: CC-BY-4.0                                     ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                       ///
///                                                                          ///
///------------------------------------------------------------ HELIX -------///

#ifndef __HELIX_TOOLCHAIN_CORE_UTF8_DECODE_HH__
#define __HELIX_TOOLCHAIN_CORE_UTF8_DECODE_HH__

/// FIXME: make skip_ascii_simd more portable by adding fallback and full
///       support for AVX2, AVX512, etc...

///
/// \file Core/Utf8Decode.hh
/// \brief fast utf-8 decoding utilities optimized for compiler hot paths.
///
/// \details
/// this file implements utf-8 decoding primitives used by the helix compiler
/// for tokenization, source indexing, and diagnostics. it includes:
///   - a precomputed lookup table for utf-8 sequence lengths (`kUtf8LengthTable`)
///   - simd-optimized ascii scanning for fast linear skipping
///   - fallback scalar decoding with proper utf-8 validation
///
/// the implementation favors performance and predictability over strict unicode
/// conformance; malformed sequences return the replacement character `0xFFFD`.
///
/// the simd routines are specialized for x86 (sse2) and arm (neon) architectures
/// and degrade cleanly to scalar behavior on other targets.
///
/// \note
/// decoding is designed to be branch-light and cache-aligned for high-frequency
/// lexer and parser use.
///
/// \see SourceManager, Lexer
///

#include <include/core.hh>
#include "Types.hh"

namespace helix {
///
/// \struct DecodeResult
/// \brief represents the result of decoding a single utf-8 sequence.
///
/// \details
/// contains the decoded unicode code point (`chr`) and the number of bytes
/// consumed (`len`). if the input sequence is invalid, `chr` is set to the
/// unicode replacement character (0xFFFD) and `len` may be set to 1.
///
struct DecodeResult {
    char32_t chr; ///< decoded codepoint or 0xFFFD on error.
    u8       len; ///< number of bytes consumed from input.
};

///
/// \brief lookup table for utf-8 byte sequence lengths.
///
/// \details
/// precomputed for all 256 byte values. values correspond to how many bytes
/// a character beginning with that leading byte should occupy.
///
/// layout is aligned to 64 bytes for cache friendliness.
///
alignas(64) static constexpr u8 Utf8LengthTable[256] = {
    // 0x00-0x7F: ASCII (1-byte)
    /* 0x00-0x7F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    // 0x80-0xBF: continuation bytes (invalid starts)
    /* 0x80-0xBF */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    // 0xC0-0xDF: 2-byte sequences
    /* 0xC0-0xDF */
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    // 0xE0-0xEF: 3-byte sequences
    /* 0xE0-0xEF */
    3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,
    // 0xF0-0xF7: 4-byte sequences
    /* 0xF0-0xF7 */
    4,4,4,4,4,4,4,4,
    // 0xF8-0xFF: invalid starts
    /* 0xF8-0xFF */
    1,1,1,1,1,1,1,1
};

///
/// \brief skips over consecutive ascii bytes using simd.
///
/// \details
/// scans the buffer for the first non-ascii byte (>= 0x80) using vectorized
/// bitmask operations. optimized for bulk ascii text in source files.
///
/// \param p    pointer to start of buffer.
/// \param end  pointer to end of buffer.
/// \return pointer to first non-ascii byte or `end` if none found.
///
static inline const u8 *skip_ascii_simd(const u8 *p, const u8 *end) noexcept {
#if defined(_x86_64_simd)
    const __m128i mask = _mm_set1_epi8(static_cast<char>(0x80));
    while (p + 16 <= end) {
        __m128i v = _mm_loadu_si128(reinterpret_cast<const __m128i *>(p));
        if (_mm_movemask_epi8(v) != 0)
            break;
        p += 16;
    }
#elif defined(_aarch64_simd)
    const uint8x16_t mask = vdupq_n_u8(0x80);
    while (p + 16 <= end) {
        uint8x16_t v    = vld1q_u8(p);
        uint8x16_t high = vandq_u8(v, mask);

        if (vmaxvq_u8(high) != 0) {
            break;
        }

        p += 16;
    }
#endif
    if (p > end) {
        p = end;
    }

    return p;
}


///
/// \brief decodes a utf-8 sequence using a lookup table.
///
/// \details
/// performs minimal validation and returns replacement char on errors.
/// overlong sequences, invalid continuations, or surrogate code points are
/// rejected.
///
/// \param s         pointer to utf-8 byte sequence.
/// \param remaining number of bytes remaining in buffer.
/// \return `DecodeResult` with codepoint and byte length.
///
static inline DecodeResult decode_utf8_lut(const u8 *s,
                                           usize     remaining) noexcept {
    if (remaining == 0) {
        return {.chr = 0xFFFD, .len = 0};
    }

    u8 b0 = s[0];

    // ASCII fast path
    if (b0 < 0x80) {
        return {.chr = b0, .len = 1};
    }

    // Invalid continuation byte as start
    if (b0 < 0xC0) {
        return {.chr = 0xFFFD, .len = 1};
    }

    u8 len = Utf8LengthTable[b0];

    if (remaining < len) {
        return {.chr = 0xFFFD, .len = 1};
    }

    char32_t cp;

    switch (len) {
        case 2: {
            u8 b1 = s[1];

            if ((b1 & 0xC0) != 0x80) {
                return {.chr = 0xFFFD, .len = 1};
            }

            cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
            if (cp < 0x80) {
                return {.chr = 0xFFFD, .len = 1};
            }
            break;
        } case 3: {
            u8 b1 = s[1];
            u8 b2 = s[2];

            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) {
                return {.chr = 0xFFFD, .len = 1};
            }

            cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
            if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) {
                return {.chr = 0xFFFD, .len = 1};
            }
            break;
        } case 4: {
            u8 b1 = s[1];
            u8 b2 = s[2];
            u8 b3 = s[3];

            if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 ||
                (b3 & 0xC0) != 0x80) {
                return {.chr = 0xFFFD, .len = 1};
            }

            cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) |
                 ((b2 & 0x3F) << 6) | (b3 & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF) {
                return {.chr = 0xFFFD, .len = 1};
            }

            break;
        } default:
            return {.chr = 0xFFFD, .len = 1};
    }

    return {.chr = cp, .len = len};
}


///
/// \brief decodes a single utf-8 block from the given buffer.
///
/// \details
/// fast path uses simd to skip ascii, then falls back to table-based
/// decoding for multibyte sequences.
///
/// \param p   pointer to current byte.
/// \param end pointer to end of buffer.
/// \param out result container for decoded character.
/// \return pointer to next byte after the decoded character.
///
inline const u8 * decode_block(const u8 *p, const u8 *end, DecodeResult &out) noexcept {
    const u8 *ascii_end = skip_ascii_simd(p, end);

    if (ascii_end != p) {
        out = {.chr = *p, .len = 1};
        return p + 1;
    }

    out = decode_utf8_lut(p, static_cast<usize>(end - p));
    return p + out.len;
}
}  // namespace helix

#endif  // __HELIX_TOOLCHAIN_CORE_UTF8_DECODE_HH__