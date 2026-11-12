/// --- The Kairo Project ------------------------------ Support/Ascii.k --- ///
///
///   Byte classes the compiler and the language server test by hand.
///
///   A single character is written as a literal at its site (`c == ('/' as
///   u8)`): that compiles to the same compare as the integer and says which
///   character it is. This file holds only what a literal cannot say: the
///   classes (blank, hex digit, ...), so each is defined once.
///
///   `pub inline fn`: the body is emitted into every unit that calls it, so
///   a test in a scanning loop costs what the hand-written compare did.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

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

pub inline fn is_hex_digit(c: u8) -> bool {
    return is_digit(c) || (c >= ('a' as u8) && c <= ('f' as u8)) || (c >= ('A' as u8) && c <= ('F' as u8))
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
