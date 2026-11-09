/// --- The Kairo Project ---------------------------- Lexer/HexParser.k --- ///
///
///   Hex digit lookup and HexParser, the incremental hex escape parser.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// \brief value of a hex digit byte: '0'-'9' -> 0-9, 'A'-'F' and 'a'-'f' ->
///        10-15, 0xFF for anything else (an invalid digit).
///
/// \details was a 256-entry `static constexpr` table built by a C++ lambda.
///          It is indexed by the low byte of the code point, so callers keep
///          passing `static_cast::<u8>(c)` exactly as they indexed the table.

pub fn hex_digit_lut(b: u8) -> u8 {
    if b >= 48 && b <= 57 { // '0'-'9'
        return b - 48
    }

    if b >= 65 && b <= 70 { // 'A'-'F'
        return b - 65 + 10
    }

    if b >= 97 && b <= 102 { // 'a'-'f'
        return b - 97 + 10
    }

    return 0xFF
}

/// \brief incremental hexadecimal digit parser
/// \details used for escape sequence decoding (\x, \u, \U)
pub class HexParser {
    var value:  usize = 0
    var digits: usize = 0

    /// \brief appends a hex digit
    /// \param c hex digit character
    /// \requires is_digit(c) == true
    inline fn push_back(self, c: char) {
        const v: u8 = hex_digit_lut(c as u8)
        self.value = self.value << 4 | (v as usize)
        ++self.digits
    }

    /// \brief checks whether character is a valid hex digit
    /// \param c input character
    /// \returns true if valid hex digit
    inline fn is_digit(self, c: char) -> bool {
        return hex_digit_lut(c as u8) != 0xFF
    }

    /// \brief returns accumulated numeric value
    /// \returns parsed value
    inline fn get_value(self) -> usize {
        return self.value
    }

    /// \brief returns number of digits consumed
    /// \returns digit count
    inline fn get_digits(self) -> usize {
        return self.digits
    }
}
