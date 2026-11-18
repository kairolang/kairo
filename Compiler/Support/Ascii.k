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

/// The value of hex digit `c`, either case; 0 for a byte that is not one.
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

/// # The same classes for a `char`
///
/// A string subscript is a `u8` on one builtin library and a `char` on the
/// other; each class takes both, so a call site reads the same on either.
/// A character past ASCII is in no class, as a non-ASCII byte is not.

/// `c` as its ASCII byte, or 0x80 (a byte in no class) when it is past ASCII.
pub inline fn ascii_byte(c: char) -> u8 {
    var v = c as u32
    return if (v < 0x80) => (v as u8) else => 0x80
}

pub inline fn is_blank(c: char) -> bool {
    return is_blank(ascii_byte(c))
}

pub inline fn is_control(c: char) -> bool {
    return is_control(ascii_byte(c))
}

pub inline fn is_digit(c: char) -> bool {
    return is_digit(ascii_byte(c))
}

pub inline fn is_ident_start(c: char) -> bool {
    return is_ident_start(ascii_byte(c))
}

pub inline fn is_ident_char(c: char) -> bool {
    return is_ident_char(ascii_byte(c))
}

pub inline fn is_hex_digit(c: char) -> bool {
    return is_hex_digit(ascii_byte(c))
}

pub inline fn hex_value(c: char) -> u8 {
    return hex_value(ascii_byte(c))
}

pub inline fn is_illegal_ascii(c: char) -> bool {
    return is_illegal_ascii(ascii_byte(c))
}

/// # Text

/// Byte offset of the first `needle` in `hay` at or after `from`;
/// usize::MAX when there is none. An empty needle is found at `from`
/// when `from` is at most `hay.size()` (as `std::string::find`).
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

/// Byte offset of the last `c` in `s`; `s.size()` when there is none.
pub fn rfind_byte(const s: string, c: u8) -> usize {
    var i = s.size()
    while i > 0 {
        i -= 1
        if s.data()[i] == c {
            return i
        }
    }

    return s.size()
}

/// The offset just past the UTF-8 sequence that starts at byte `i` of `s`:
/// `i + 1` for an ASCII byte, past the continuation bytes for a lead byte.
/// A cut at the result never splits a character.
pub fn utf8_next(const s: string, i: usize) -> usize {
    var e = i + 1
    while e < s.size() && (s.data()[e] & 0xc0) == 0x80 {
        e += 1
    }

    return e
}

/// The largest character boundary of `s` at or below byte `i` (`size()`
/// when `i` is past the end): a cut there never splits a character.
pub fn utf8_floor(const s: string, i: usize) -> usize {
    if i >= s.size() {
        return s.size()
    }

    var b = i
    while b > 0 && (s.data()[b] & 0xc0) == 0x80 {
        b -= 1
    }

    return b
}

/// The smallest character boundary of `s` at or above byte `i` (`size()`
/// when `i` is past the end).
pub fn utf8_ceil(const s: string, i: usize) -> usize {
    var b = i
    while b < s.size() && (s.data()[b] & 0xc0) == 0x80 {
        b += 1
    }

    return if b < s.size() => b else => s.size()
}

/// Whether the bytes of `w` stand in `s` at byte `i`. A byte compare: `i`
/// need not be a character boundary, and a window past the end is false.
pub fn has_at(const s: string, i: usize, const w: string) -> bool {
    if i > s.size() || w.size() > s.size() - i {
        return false
    }

    for var k: usize = 0; k < w.size(); ++k {
        if s.data()[i + k] != w.data()[k] {
            return false
        }
    }

    return true
}

/// The pieces of `s` between occurrences of `sep`, in order.
///
/// `keep_empty` false drops every empty piece (`"a--b-"` on `-` is `a`,
/// `b`). True keeps them, except the one after a trailing separator, so
/// text that ends in its separator has no phantom last piece (`"a\n\nb\n"`
/// on `\n` is `a`, `""`, `b`); an empty `s` has no pieces either way.
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

/// `s` without its leading and trailing spaces and tabs. Line breaks are
/// kept: a caller trimming lines has already cut at them.
pub fn trim(const s: string) -> string {
    return trim_end(trim_start(s))
}

/// `s` without its leading spaces and tabs.
pub fn trim_start(const s: string) -> string {
    var a: usize = 0
    while a < s.size() && (s.data()[a] == (' ' as u8) || s.data()[a] == ('\t' as u8)) {
        a += 1
    }

    return s[a..].to_owned()
}

/// `s` without its trailing spaces and tabs.
pub fn trim_end(const s: string) -> string {
    var b = s.size()
    while b > 0 && (s.data()[b - 1] == (' ' as u8) || s.data()[b - 1] == ('\t' as u8)) {
        b -= 1
    }

    return s[..b].to_owned()
}

/// The value of the decimal digits that start `s`, up to the first byte
/// that is not one; 0 when `s` starts with none. A value past u64::MAX
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
/// `a` orders before `b`, byte by byte: the comparator a C++ sort of a
/// string vector takes. The default `<` of std::sort is not defined for the
/// Kairo string on every builtin library, and a closure's `const` parameter
/// is a value in its `fn` type, which copies; a function's is a reference.
pub fn string_less(const a: string, const b: string) -> bool {
    return a < b
}

pub fn copy_strings(const v: cxx::std::vector<string>) -> cxx::std::vector<string> {
    var out = cxx::std::vector<string>()
    out.reserve(v.size())
    for *s in v {
        out.push_back(s->copy())
    }

    return out
}

/// A copy of the bytes `sr` views.
pub fn string_from_ref(sr: llvm::StringRef) -> string {
    if sr.size() == 0 {
        return ""
    }

    return string(
        unsafe ((sr.data() as unsafe *const u8) as *const u8),
        sr.size(),
    )
}
