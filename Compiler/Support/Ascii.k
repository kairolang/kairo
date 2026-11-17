/// --- The Kairo Project ------------------------------ Support/Ascii.k --- ///
///
///   Byte classes and the small text utilities the compiler and the
///   language server would otherwise write by hand.
///
///   A single character is written as a literal at its site (`c == ('/' as
///   u8)`): that compiles to the same compare as the integer and says which
///   character it is. This file holds what a literal cannot say: the
///   classes (blank, hex digit, identifier, ...), and the byte-wise string
///   operations `string` itself has no method for (find, split, trim,
///   decimal parse), so each is defined once.
///
///   `pub inline fn`: the body is emitted into every unit that calls it, so
///   a test in a scanning loop costs what the hand-written compare did.
///
///   Everything here is bytes, not codepoints: a non-ASCII byte is in no
///   class, and offsets are byte offsets.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "vector"

/// Space, tab, line feed or carriage return: the whitespace a scan of one
/// line or one token's neighbourhood skips (not form feed or vertical tab).
pub inline fn is_blank(c: u8) -> bool {
    return c == (' ' as u8) || c == ('\t' as u8) || c == ('\n' as u8) || c == ('\r' as u8)
}

/// A C0 control byte (below space). DEL (127) is not one here.
pub inline fn is_control(c: u8) -> bool {
    return c < (' ' as u8)
}

pub inline fn is_digit(c: u8) -> bool {
    return c >= ('0' as u8) && c <= ('9' as u8)
}

/// `[A-Za-z_]`: a byte that can start a C identifier (and a plain Kairo
/// one). A Kairo name may also carry `#` or non-ASCII bytes; a caller that
/// accepts those tests them itself.
pub inline fn is_ident_start(c: u8) -> bool {
    return (c >= ('a' as u8) && c <= ('z' as u8))
        || (c >= ('A' as u8) && c <= ('Z' as u8))
        || c == ('_' as u8)
}

/// `[A-Za-z0-9_]`: a byte that can continue a C identifier.
pub inline fn is_ident_char(c: u8) -> bool {
    return is_ident_start(c) || is_digit(c)
}

pub inline fn is_hex_digit(c: u8) -> bool {
    return is_digit(c)
        || (c >= ('a' as u8) && c <= ('f' as u8))
        || (c >= ('A' as u8) && c <= ('F' as u8))
}

/// The value of hex digit \p c, either case; 0 for a byte that is not one.
pub inline fn hex_value(c: u8) -> u8 {
    if is_digit(c) {
        return c - ('0' as u8)
    }

    if c >= ('a' as u8) && c <= ('f' as u8) {
        return c - ('a' as u8) + 10
    }

    if c >= ('A' as u8) && c <= ('F' as u8) {
        return c - ('A' as u8) + 10
    }

    return 0
}

/// `$`, a backtick, `\` or DEL: an ASCII byte no Kairo token holds outside
/// a literal or a comment (Lexer::lex_illegal_ascii lexes a run of them as
/// one unknown token).
pub inline fn is_illegal_ascii(c: u8) -> bool {
    return c == ('$' as u8) || c == ('`' as u8) || c == ('\\' as u8) || c == 0x7f
}

/// # Text

/// Byte offset of the first \p needle in \p hay at or after \p from;
/// usize::MAX when there is none. An empty needle is found at \p from
/// when \p from is at most `hay.size()` (as `std::string::find`).
pub fn find(const hay: string, const needle: string, from: usize) -> usize {
    var n = hay.size()
    var m = needle.size()
    if from > n || m > n - from {
        return usize::MAX
    }

    for var i: usize = from; i + m <= n; ++i {
        var j: usize = 0
        while j < m && hay.data()[i + j] == needle.data()[j] {
            j += 1
        }

        if j == m {
            return i
        }
    }

    return usize::MAX
}

/// The pieces of \p s between occurrences of \p sep, in order.
///
/// \p keep_empty false drops every empty piece (`"a--b-"` on `-` is `a`,
/// `b`). True keeps them, except the one after a trailing separator, so
/// text that ends in its separator has no phantom last piece (`"a\n\nb\n"`
/// on `\n` is `a`, `""`, `b`); an empty \p s has no pieces either way.
pub fn split(const s: string, sep: u8, keep_empty: bool) -> [string] {
    var out:   [string]
    var start: usize    = 0
    for var i: usize = 0; i < s.size(); ++i {
        if s.data()[i] != sep {
            continue
        }

        if keep_empty || i > start {
            out.push(s[start..i].to_owned())
        }

        start = i + 1
    }

    if start < s.size() {
        out.push(s[start..].to_owned())
    }

    return out
}

/// \p s without its leading and trailing spaces and tabs. Line breaks are
/// kept: a caller trimming lines has already cut at them.
pub fn trim(const s: string) -> string {
    return trim_end(trim_start(s))
}

/// \p s without its leading spaces and tabs.
pub fn trim_start(const s: string) -> string {
    var a: usize = 0
    while a < s.size() && (s.data()[a] == (' ' as u8) || s.data()[a] == ('\t' as u8)) {
        a += 1
    }

    return s[a..].to_owned()
}

/// \p s without its trailing spaces and tabs.
pub fn trim_end(const s: string) -> string {
    var b = s.size()
    while b > 0 && (s.data()[b - 1] == (' ' as u8) || s.data()[b - 1] == ('\t' as u8)) {
        b -= 1
    }

    return s[..b].to_owned()
}

/// The value of the decimal digits that start \p s, up to the first byte
/// that is not one; 0 when \p s starts with none. A value past u64::MAX
/// saturates there.
pub fn parse_decimal(const s: string) -> u64 {
    var n: u64 = 0
    for var i: usize = 0; i < s.size() && is_digit(s.data()[i]); ++i {
        var d = (s.data()[i] - ('0' as u8)) as u64
        if n > (u64::MAX - d) / 10 {
            return u64::MAX
        }

        n = n * 10 + d
    }

    return n
}

/// A copy of `v`, string by string.
///
/// A C++ vector of strings has no copy of its own.
pub fn copy_strings(const v: cxx::std::vector<string>) -> cxx::std::vector<string> {
    var out = cxx::std::vector<string>()
    out.reserve(v.size())
    for *s in v {
        out.push_back(s->copy())
    }

    return out
}

/// A copy of the bytes \p sr views.
pub fn string_from_ref(sr: llvm::StringRef) -> string {
    if sr.size() == 0 {
        return ""
    }

    return string(
        unsafe ((sr.data() as unsafe *const u8) as *const u8),
        sr.size(),
    )
}
