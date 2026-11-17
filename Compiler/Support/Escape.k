/// --- The Kairo Project ----------------------------- Support/Escape.k --- ///
///
///   The C string escaper and the JSON string escaper: every C++ literal
///   the compiler emits, every fix-it line it prints and every JSON string
///   it writes is spelled here.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Support::Ascii::{
    hex_value,
    is_hex_digit,
}

/// How c_escape spells a byte that cannot stand for itself.
pub enum CEscapeStyle {
    /// Every byte outside printable ASCII (0x20..0x7e) as a three-digit octal
    /// escape (`\012`). For emitted C++: an octal escape reads at most three
    /// digits, so a digit after it stays a character, where `\x` would read it
    /// into the escape.
    Octal,

    /// Line feed, tab and carriage return as `\n`, `\t`, `\r`, and every
    /// other byte as it is. For text a person reads on one line (a fix-it, an
    /// assembler string): no line break survives, and UTF-8 stays legible.
    /// Not clang's write_escaped, which writes `\r` and every non-ASCII byte
    /// in octal.
    Readable,
}

/// The bytes [\p p, \p p + \p len) escaped for the inside of a C or C++
/// narrow string literal, without the quotes: `"` and `\` are backslashed,
/// and \p style says what happens to the rest.
pub fn c_escape(p: unsafe *const u8, len: usize, style: CEscapeStyle) -> string {
    var out = ""
    for var i: usize = 0; i < len; ++i {
        var b = p[i]
        if b == ('"' as u8) {
            out += "\\\""
            continue
        }

        if b == ('\\' as u8) {
            out += "\\\\"
            continue
        }

        if b >= 0x20 && b < 0x7f {
            out.push_back(b)
            continue
        }

        if style == CEscapeStyle::Readable {
            if b == ('\n' as u8) {
                out += "\\n"
                continue
            }

            if b == ('\t' as u8) {
                out += "\\t"
                continue
            }

            if b == ('\r' as u8) {
                out += "\\r"
                continue
            }

            out.push_back(b)
            continue
        }

        out += "\\"
        out.push_back(('0' as u8) + (b >> 6 & 7))
        out.push_back(('0' as u8) + (b >> 3 & 7))
        out.push_back(('0' as u8) + (b & 7))
    }

    return out
}

pub fn c_escape(const s: string, style: CEscapeStyle) -> string {
    return c_escape(unsafe (s.data() as unsafe *const u8), s.size(), style)
}

/// \p s as a C++ narrow string literal, quotes included, every byte outside
/// printable ASCII in octal (CEscapeStyle::Octal).
pub fn c_string_literal(const s: string) -> string {
    return "\"" + c_escape(s, CEscapeStyle::Octal) + "\""
}

pub fn c_string_literal(p: unsafe *const u8, len: usize) -> string {
    return "\"" + c_escape(p, len, CEscapeStyle::Octal) + "\""
}

/// \p s as a JSON string, quotes included (RFC 8259 section 7): `"` and `\`
/// backslashed, a byte below 0x20 as its two-character escape (backspace,
/// form feed, line feed, carriage return, tab) or as `\u00XX`, every other
/// byte as it is. JSON text is UTF-8, so non-ASCII bytes pass through: the
/// result is valid JSON when \p s is valid UTF-8.
pub fn json_string(const s: string) -> string {
    var out = "\""
    for var i: usize = 0; i < s.size(); ++i {
        var c = s[i]
        if c == ('"' as u8) {
            out += "\\\""
        } else if c == ('\\' as u8) {
            out += "\\\\"
        } else if c >= 0x20 {
            out.push_back(c)
        } else if c == ('\n' as u8) {
            out += "\\n"
        } else if c == ('\t' as u8) {
            out += "\\t"
        } else if c == ('\r' as u8) {
            out += "\\r"
        } else if c == 0x08 {
            out += "\\b"
        } else if c == 0x0c {
            out += "\\f"
        } else {
            var hex = "0123456789abcdef"
            out += "\\u00"
            out.push_back(hex[(c >> 4) as usize])
            out.push_back(hex[(c & 15) as usize])
        }
    }

    out += "\""
    return out
}

/// Reads the JSON string that starts at the `"` at \p at in \p s, as
/// json_string writes one, into \p out (decoded). Returns the index just
/// past its closing quote, or usize::MAX when there is no well-formed
/// string there (\p out is then unspecified). A `\uXXXX` escape is written
/// as UTF-8; a surrogate is refused, since json_string never writes one.
pub fn json_string_read(const s: string, at: usize, @inout out: string) -> usize {
    out = ""
    if at >= s.size() || s[at] != ('"' as u8) {
        return usize::MAX
    }

    var i = at + 1
    while i < s.size() {
        var c = s[i]
        if c == ('"' as u8) {
            return i + 1
        }

        if c != ('\\' as u8) {
            out.push_back(c)
            i += 1
            continue
        }

        if i + 1 >= s.size() {
            return usize::MAX
        }

        var e = s[i + 1]
        i += 2
        if e == ('"' as u8) || e == ('\\' as u8) || e == ('/' as u8) {
            out.push_back(e)
        } else if e == ('n' as u8) {
            out.push_back('\n' as u8)
        } else if e == ('t' as u8) {
            out.push_back('\t' as u8)
        } else if e == ('r' as u8) {
            out.push_back('\r' as u8)
        } else if e == ('b' as u8) {
            out.push_back(0x08 as u8)
        } else if e == ('f' as u8) {
            out.push_back(0x0c as u8)
        } else if e == ('u' as u8) {
            if i + 4 > s.size() {
                return usize::MAX
            }

            var cp: u32 = 0
            for var k: usize = 0; k < 4; ++k {
                if !is_hex_digit(s[i + k]) {
                    return usize::MAX
                }

                cp = (cp << 4) | (hex_value(s[i + k]) as u32)
            }

            i += 4
            if cp >= 0xd800 && cp < 0xe000 {
                return usize::MAX
            }

            if cp < 0x80 {
                out.push_back(cp as u8)
            } else if cp < 0x800 {
                out.push_back((0xc0 | (cp >> 6)) as u8)
                out.push_back((0x80 | (cp & 0x3f)) as u8)
            } else {
                out.push_back((0xe0 | (cp >> 12)) as u8)
                out.push_back((0x80 | ((cp >> 6) & 0x3f)) as u8)
                out.push_back((0x80 | (cp & 0x3f)) as u8)
            }
        } else {
            return usize::MAX
        }
    }

    return usize::MAX
}
