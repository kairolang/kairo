/// --- The Kairo Project -------------------------- Lexer/OctalParser.k --- ///
///
///   OctalParser, the incremental octal digit parser for \ooo escapes.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// \brief incremental octal digit parser
/// \details used for byte escape sequences (\ooo)

pub class OctalParser {
    var value:  usize = 0
    var digits: usize = 0

    /// \brief appends an octal digit
    /// \param c octal digit character
    /// \requires is_digit(c) == true
    inline fn push_back(self, c: char) {
        self.value = self.value << 3 | (((c as u32) - ('0' as u32)) as usize)
        ++self.digits
    }

    /// \brief checks whether character is a valid octal digit
    /// \param c input character
    /// \returns true if valid octal digit
    inline fn is_digit(self, c: char) -> bool {
        return (c as u32) - ('0' as u32) <= 7
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
