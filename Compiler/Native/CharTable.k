/// --- The Kairo Project --------------------------- Native/CharTable.k --- ///
///
///   Character classification tables for the lexer: ASCII classes and
///   name/operator flags, and char32 normalization. The Unicode properties
///   of every other character are Lexer/UnicodeTables.k.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The operator/punctuation characters.
eval fn is_unicode_operator_char(c: char) -> bool {
    return c == '{'
        || c == '}'
        || c == '~'
        || c == '('
        || c == '<'
        || c == ')'
        || c == '\\'
        || c == '['
        || c == '>'
        || c == ']'
        || c == '='
        || c == '-'
        || c == '!'
        || c == '+'
        || c == '?'
        || c == '*'
        || c == '@'
        || c == '/'
        || c == ';'
        || c == '%'
        || c == ':'
        || c == '^'
        || c == ','
        || c == '|'
        || c == '.'
        || c == '&'
}

/// The keyword-safe name characters: [A-Za-z0-9_].
eval fn is_unicode_keyword_char(c: char) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

/// `@open`, as a C++ enum is: a value no variant names is still a value.
@open pub enum CharClass derives u8 {
    Unassigned = 0,
    Identifier,
    Number,
    Operator,
    String,
    Whitespace,
    NewLine,
    Illegal,
}

/// An eval fn cannot return an array, so each table is the one field of a
/// struct; the struct's layout is the array's.
pub struct AsciiClassTable {
    pub var t: [CharClass; 128]
}

pub struct AsciiLexFlagTable {
    pub var t: [u8; 128]
}

eval fn build_ascii_class() -> AsciiClassTable {
    var r: AsciiClassTable
    for var i: i32 = 0; i < 128; ++i {
        r.t[i] = CharClass::Unassigned
    }

    // simple whitespace
    for var i: i32 = 0; i <= 32; ++i {
        r.t[i] = CharClass::Whitespace
    }

    r.t['\n' as i32] = CharClass::NewLine
    r.t['\r' as i32] = CharClass::NewLine
    r.t[' ' as i32]  = CharClass::Whitespace
    r.t['\t' as i32] = CharClass::Whitespace
    r.t[0x0B]        = CharClass::Whitespace // '\v'
    r.t[0x0C]        = CharClass::Whitespace // '\f'

    // a-z, A-Z
    for var c: i32 = 'a' as i32; c <= ('z' as i32); ++c {
        r.t[c] = CharClass::Identifier
    }

    for var c: i32 = 'A' as i32; c <= ('Z' as i32); ++c {
        r.t[c] = CharClass::Identifier
    }

    // digits
    for var c: i32 = '0' as i32; c <= ('9' as i32); ++c {
        r.t[c] = CharClass::Number
    }

    r.t['_' as i32] = CharClass::Identifier
    r.t['#' as i32] = CharClass::Identifier

    // operators
    // NUL is not an operator: it keeps the class the whitespace loop gave
    // it, and SourceManager::validate_utf8 reports every NUL byte of a file
    // once, as S011E.
    for var i: i32 = 1; i < 128; ++i {
        if is_unicode_operator_char(i as char) {
            r.t[i] = CharClass::Operator
        }
    }

    // strings
    r.t['"' as i32]  = CharClass::String
    r.t['\'' as i32] = CharClass::String

    // fill remaining
    for var i: i32 = 0; i < 128; ++i {
        if r.t[i] == CharClass::Unassigned {
            r.t[i] = CharClass::Illegal
        }
    }

    return r
}

/// ASCII LUT (fast path: 0x00-0x7F)
@align(64) pub eval ASCII_CLASS: AsciiClassTable = build_ascii_class()

/// Per-byte lexical flag table for the ASCII range.
///
/// is_valid_name and is_valid_symbol test sparse sets, which as a compare
/// chain or a bounds-checked jump table are far too big to inline into the
/// scan loops that call them once per character. A load and a mask is a
/// couple of instructions and inlines.
///
/// Built from the two set predicates above rather than from a transcribed
/// character list, so the table cannot drift from the sets. It is built at
/// compile time; nothing here survives to runtime but the bytes.
@open pub enum LexCharFlag derives u8 {
    LEX_NAME = 1 << 0, ///< is_unicode_keyword_char ([A-Za-z0-9_])
    LEX_OP   = 1 << 1, ///< is_unicode_operator_char
}

eval fn build_ascii_lex_flags() -> AsciiLexFlagTable {
    var r: AsciiLexFlagTable
    for var i: i32 = 0; i < 128; ++i {
        r.t[i] = 0
    }

    for var i: i32 = 0; i < 128; ++i {
        if is_unicode_keyword_char(i as char) {
            r.t[i] |= LexCharFlag::LEX_NAME as u8
        }

        if is_unicode_operator_char(i as char) {
            r.t[i] |= LexCharFlag::LEX_OP as u8
        }
    }

    return r
}

@align(64) pub eval ASCII_LEX_FLAGS: AsciiLexFlagTable = build_ascii_lex_flags()

/// \brief classifies a character for identifier/keyword scanning.
/// \returns 0 not a name character, 1 keyword-safe ASCII, 2 identifier-only.
pub inline fn name_char_kind(c: char, len: u8) -> u8 {
    if len == 0 || c == '\0' {
        return 0
    }

    // len == 1 means the codepoint came from a single byte: ASCII, or an
    // invalid byte the decoder replaced with U+FFFD. The replacement must not
    // index the 128-entry table (an out-of-bounds read). It stays a name
    // character: S072E already reported the byte, and ending the identifier
    // at it would only add a parse error on top. A character of more than
    // one byte is the lexer's to judge (Lexer::is_valid_name, XID_Continue)
    // and does not reach here.
    if len > 1 || c == '#' || (c as u32) > 127 {
        return 2
    }

    return if (ASCII_LEX_FLAGS.t[c as u32] & (LexCharFlag::LEX_NAME as u8)) != 0 => 1 else => 0
}

/// \brief true when \p c is one of the operator/punctuation characters.
pub inline fn is_operator_char(c: char, len: u8) -> bool {
    if len != 1 || c == '\0' || (c as u32) > 127 {
        return false
    }

    return (ASCII_LEX_FLAGS.t[c as u32] & (LexCharFlag::LEX_OP as u8)) != 0
}

/// Replacement Table (common confusables -> normalized form)
pub inline fn normalize_char32(ch: char) -> char {
    const v: u32 = ch as u32
    if v < 128 {
        return ch
    }

    // fullwidth ASCII range (U+FF01-U+FF5E)
    if v >= 0xFF01 && v <= 0xFF5E {
        return (v - 0xFEE0) as char
    }

    match v {
        // quotes / apostrophes
        case 0x2018, 0x2019, 0x201A, 0x201B { // ‘ ’ ‚ ‛
            return '\''
        } case 0x2039 { // ‹
            return '<'
        } case 0x203A { // ›
            return '>'
        } case 0x201C, 0x201D, 0x201F, 0x201E { // “ ” ‟ „
            return '"'
        } case 0x00AB { // «
            return '<'
        } case 0x00BB { // »
            return '>'
        }

        // dashes / ellipsis
        case 0x2013, 0x2014, 0x2012, 0x2015 { // – — ‒ ―
            return '-'
        } case 0x2026 { // … FIXME: make this work right and return '...'
            return '.'
        }

        // spacing
        case 0x00A0, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
             0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 {
            return ' '
        }

        // mathematical alphabets: 𝐀-𝑧 -> A-z
        // FIXME: remove this users might use mathematical alphanumerics
        //        intentionally, but for now we want to avoid confusion with
        //        ASCII letters and digits.
        case _ {
            if v >= 0x1D400 && v <= 0x1D419 {
                return (('A' as u32) + (v - 0x1D400)) as char
            }

            if v >= 0x1D41A && v <= 0x1D433 {
                return (('a' as u32) + (v - 0x1D41A)) as char
            }

            if v >= 0x1D7CE && v <= 0x1D7D7 {
                return (('0' as u32) + (v - 0x1D7CE)) as char
            }
        }
    }

    return ch
}

/// \brief the class of an ASCII character. \p c is below 128; the lexer
///        classifies every other character from its Unicode tables
///        (Lexer::classify_unicode).
pub inline fn classify_ascii(c: char) -> CharClass {
    return ASCII_CLASS.t[(c as u32) & 0x7F]
}
