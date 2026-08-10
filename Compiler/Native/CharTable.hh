/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#pragma once

#include <array>
#include <cstdint>
#include <cwctype>
#include <include/core.hh>

namespace kairo {

#define MACRO_UNICODE_OPERATOR_CHAR_CASES U'{': \
    case U'}': case U'~':   \
    case U'(': case U'<':   \
    case U')': case U'\\':  \
    case U'[': case U'>':   \
    case U']': case U'=':   \
    case U'-': case U'!':   \
    case U'+': case U'?':   \
    case U'*': case U'@':   \
    case U'/': case U';':   \
    case U'%': case U':':   \
    case U'^': case U',':   \
    case U'|': case U'.':   \
    case U'&'

#define MACRO_UNICODE_KEYWORD_CASES U'q': \
               case U'Q': case U'1':   \
    case U'w': case U'W': case U'2':   \
    case U'e': case U'E': case U'3':   \
    case U'r': case U'R': case U'4':   \
    case U't': case U'T': case U'5':   \
    case U'y': case U'Y': case U'6':   \
    case U'u': case U'U': case U'7':   \
    case U'i': case U'I': case U'8':   \
    case U'o': case U'O': case U'9':   \
    case U'p': case U'P': case U'0':   \
    case U'a': case U'A': case U'_':   \
    case U's': case U'S':              \
    case U'd': case U'D':              \
    case U'f': case U'F':              \
    case U'g': case U'G':              \
    case U'h': case U'H':              \
    case U'j': case U'J':              \
    case U'k': case U'K':              \
    case U'l': case U'L':              \
    case U'z': case U'Z':              \
    case U'x': case U'X':              \
    case U'c': case U'C':              \
    case U'v': case U'V':              \
    case U'b': case U'B':              \
    case U'n': case U'N':              \
    case U'm': case U'M'

enum class CharClass : uint8_t {
    Unassigned = 0,
    Identifier,
    Number,
    Operator,
    String,
    Whitespace,
    NewLine,
    Illegal
};

/// ASCII LUT (fast path: 0x00-0x7F)
alignas(64) static constexpr array<CharClass, 128> ASCII_CLASS = [] {
    array<CharClass, 128> t{};
    t.fill(CharClass::Unassigned);

    // simple whitespace
    for (int i = 0; i <= 32; ++i)
        t[i] = CharClass::Whitespace;

    t['\n'] = CharClass::NewLine;
    t['\r'] = CharClass::NewLine;
    t[' ']  = CharClass::Whitespace;
    t['\t'] = CharClass::Whitespace;
    t['\v'] = CharClass::Whitespace;
    t['\f'] = CharClass::Whitespace;

    // a-z, A-Z
    for (int c = 'a'; c <= 'z'; ++c) {
        t[c] = CharClass::Identifier;
    }
    
    for (int c = 'A'; c <= 'Z'; ++c) {
        t[c] = CharClass::Identifier;
    }

    // digits
    for (int c = '0'; c <= '9'; ++c) {
        t[c] = CharClass::Number;
    }

    t['_'] = CharClass::Identifier;
    t['#'] = CharClass::Identifier;

    // operators
    constexpr const char ops[] = "{}()[]+-*/%^|&~<>!=?@:;,.\\";
    for (char c : ops)
        t[static_cast<unsigned char>(c)] = CharClass::Operator;

    // strings
    t['"']  = CharClass::String;
    t['\''] = CharClass::String;

    // fill remaining
    for (int i = 0; i < 128; ++i) {
        if (t[i] == CharClass::Unassigned) {
            t[i] = CharClass::Illegal;
        }
    }

    return t;
}();

/// Per-byte lexical flag table for the ASCII range.
///
/// is_valid_name and is_valid_symbol were switches over the two case-list
/// macros above. Those sets are sparse, so they lower to compare chains or a
/// bounds-checked jump table - 1,969 and 588 self samples respectively on the
/// 1 GiB benchmark - and the bodies were far too big to inline into the scan
/// loops that call them once per character. A load and a mask is a couple of
/// instructions and inlines.
///
/// Built FROM the macros rather than from a transcribed character list, so the
/// table cannot drift from the switches that define the sets. The switch runs
/// at constexpr time; nothing here survives to runtime but the bytes.
enum LexCharFlag : u8 {
    LEX_NAME = 1u << 0, ///< in MACRO_UNICODE_KEYWORD_CASES  ([A-Za-z0-9_])
    LEX_OP   = 1u << 1, ///< in MACRO_UNICODE_OPERATOR_CHAR_CASES
};

alignas(64) static constexpr array<u8, 128> ASCII_LEX_FLAGS = [] {
    array<u8, 128> t{};
    t.fill(0);

    for (u32 i = 0; i < 128; ++i) {
        switch (static_cast<char32_t>(i)) {
            case MACRO_UNICODE_KEYWORD_CASES: t[i] |= LEX_NAME; break;
            default: break;
        }

        switch (static_cast<char32_t>(i)) {
            case MACRO_UNICODE_OPERATOR_CHAR_CASES: t[i] |= LEX_OP; break;
            default: break;
        }
    }

    return t;
}();

/// \brief classifies a character for identifier/keyword scanning.
/// \returns 0 not a name character, 1 keyword-safe ASCII, 2 identifier-only.
inline u8 name_char_kind(char32_t c, u8 len) noexcept {
    if (len == 0 || c == U'\0') {
        return 0;
    }

    // len == 1 means the codepoint came from a single byte, so it is ASCII.
    if (len > 1 || c == U'#') {
        return 2;
    }

    return (ASCII_LEX_FLAGS[c] & LEX_NAME) ? u8(1) : u8(0);
}

/// \brief true when \p c is one of the operator/punctuation characters.
inline bool is_operator_char(char32_t c, u8 len) noexcept {
    if (len != 1 || c == U'\0' || c > 127) {
        return false;
    }

    return (ASCII_LEX_FLAGS[c] & LEX_OP) != 0;
}

/// Unicode Range Table
struct UnicodeRange {
    char32_t  start;
    char32_t  end;
    CharClass cls;
};

static constexpr UnicodeRange UNICODE_RANGES[] = {
    // NBSP
    {.start = 0x00A0, .end = 0x00A0, .cls = CharClass::Whitespace},
    // Combining marks
    {.start = 0x0300, .end = 0x036F, .cls = CharClass::Identifier},
    // Greek
    {.start = 0x0370, .end = 0x03FF, .cls = CharClass::Identifier},
    // Cyrillic
    {.start = 0x0400, .end = 0x04FF, .cls = CharClass::Identifier},
    // Armenian
    {.start = 0x0530, .end = 0x058F, .cls = CharClass::Identifier},
    // Hebrew
    {.start = 0x0590, .end = 0x05FF, .cls = CharClass::Identifier},
    // Arabic
    {.start = 0x0600, .end = 0x06FF, .cls = CharClass::Identifier},
    // Devanagari
    {.start = 0x0900, .end = 0x097F, .cls = CharClass::Identifier},
    // Hiragana
    {.start = 0x3040, .end = 0x309F, .cls = CharClass::Identifier},
    // Katakana
    {.start = 0x30A0, .end = 0x30FF, .cls = CharClass::Identifier},
    // CJK Unified Ideographs
    {.start = 0x4E00, .end = 0x9FFF, .cls = CharClass::Identifier},
    // spaces and punctuation
    {.start = 0x2000, .end = 0x206F, .cls = CharClass::Whitespace},
    // letterlike symbols
    {.start = 0x2100, .end = 0x214F, .cls = CharClass::Identifier},
    // math alphanumerics
    {.start = 0x1D400, .end = 0x1D7FF, .cls = CharClass::Identifier},
    // illegal range (non-characters)
    {.start = 0, .end = 0, .cls = CharClass::Illegal}};

/// Replacement Table (common confusables -> normalized form)
inline char32_t normalize_char32(char32_t ch) noexcept {
    if (ch < 128) {
        return ch;
    }

    // fullwidth ASCII range (U+FF01-U+FF5E)
    if (ch >= U'！' && ch <= U'～') {
        return ch - 0xFEE0;
    }

    switch (ch) {
        // quotes / apostrophes
        case U'‘':
        case U'’':
        case U'‚':
        case U'‛':
            return U'\'';
        case U'‹':
            return U'<';
        case U'›':
            return U'>';

        case U'“':
        case U'”':
        case U'‟':
        case U'„':
            return U'"';
        case U'«':
            return U'<';
        case U'»':
            return U'>';

        // dashes / ellipsis
        case U'–':
        case U'—':
        case U'‒':
        case U'―':
            return U'-';
        case U'…':  // FIXME: make this work right and return '...'
            return U'.';

        // spacing
        case U'\u00A0':
        case U'\u2000':
        case U'\u2001':
        case U'\u2002':
        case U'\u2003':
        case U'\u2004':
        case U'\u2005':
        case U'\u2006':
        case U'\u2007':
        case U'\u2008':
        case U'\u2009':
        case U'\u200A':
        case U'\u202F':
        case U'\u205F':
        case U'\u3000':
            return U' ';

        // mathematical alphabets: 𝐀-𝑧 -> A-z
        // FIXME: remove this users might use mathematical alphanumerics
        //        intentionally, but for now we want to avoid confusion with
        //        ASCII letters and digits.
        default:
            if (ch >= 0x1D400 && ch <= 0x1D419) {
                return U'A' + (ch - 0x1D400);
            }
            if (ch >= 0x1D41A && ch <= 0x1D433) {
                return U'a' + (ch - 0x1D41A);
            }
            if (ch >= 0x1D7CE && ch <= 0x1D7D7) {
                return U'0' + (ch - 0x1D7CE);
            }

            break;
    }

    return ch;
}

///------------------------------------------------------------
///  Unicode classification (for non-ASCII chars)
///------------------------------------------------------------
inline CharClass classify_unicode(char32_t ch) noexcept {
    if (libcxx::iswspace(static_cast<wint_t>(ch)) != 0) {
        return CharClass::Whitespace;
    }

    if ((libcxx::iswalpha(static_cast<wint_t>(ch)) != 0) ||
        (libcxx::iswdigit(static_cast<wint_t>(ch)) != 0)) {
        return CharClass::Identifier;
    }

    // fallback to range table
    for (const auto &r : UNICODE_RANGES) {
        if (ch >= r.start && ch <= r.end) {
            return r.cls;
        }
    }

    return CharClass::Illegal;
}

inline CharClass classify_char32(char32_t raw) noexcept {
    if (raw < 128) {
        return ASCII_CLASS[raw];
    }

    return classify_unicode(raw);
}
}  // namespace kairo
