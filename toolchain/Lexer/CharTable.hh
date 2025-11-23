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

#pragma once

#include <array>
#include <cstdint>
#include <cwctype>
#include <include/core.hh>

namespace helix {

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

/// Replacement Table (common confusables → normalized form)
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

        // mathematical alphabets: 𝐀-𝑧 → A-z
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
}  // namespace helix
