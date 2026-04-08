/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

/// \brief incremental octal digit parser
/// \details used for byte escape sequences (\ooo)
class OctalParser {
    var value:  usize = 0;
    var digits: usize = 0;

    /// \brief appends an octal digit
    /// \param c octal digit character
    /// \requires is_digit(c) == true
    inline eval fn push_back(self, c: char32) {
        self.value = (self.value << 3) | (static_cast::<usize>(c - '0'));
        ++(self.digits);
    }

    /// \brief checks whether character is a valid octal digit
    /// \param c input character
    /// \returns true if valid octal digit
    inline eval fn is_digit(self, c: char32) -> bool {
        return static_cast::<u8>(c - '0') <= 7;
    }

    /// \brief returns accumulated numeric value
    /// \returns parsed value
    inline eval fn get_value(self) -> usize {
        return self.value;
    }

    /// \brief returns number of digits consumed
    /// \returns digit count
    inline eval fn get_digits(self) -> usize {
        return self.digits;
    }
}
