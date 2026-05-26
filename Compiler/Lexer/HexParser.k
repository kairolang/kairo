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

/// \brief incremental hexadecimal digit parser
/// \details used for escape sequence decoding (\x, \u, \U)
class HexParser {
    var value:  usize = 0;
    var digits: usize = 0;

    /// lookup table for hex digit to value conversion
    /// 0xFF indicates invalid digit
    __inline_cpp("static constexpr array<u8, 256> hex_lut = [] {
        array<u8, 256> lut;
        lut.fill(0xFF);

        for (u8 i{}; i <= 9; ++i) lut[static_cast<u8>(U'0') + i] = i;
        for (u8 i{}; i <= 5; ++i) {
            lut[static_cast<u8>(U'A') + i] = 10 + i;
            lut[static_cast<u8>(U'a') + i] = 10 + i;
        }

        return lut;
    }()");

    /// \brief appends a hex digit
    /// \param c hex digit character
    /// \requires is_digit(c) == true
    inline eval fn push_back(self, c: char32) {
        const v: u8 = hex_lut[static_cast::<u8>(c) & 0xFF];
        self.value = (self.value << 4) | static_cast::<usize>(v);
        ++(self.digits);
    }

    /// \brief checks whether character is a valid hex digit
    /// \param c input character
    /// \returns true if valid hex digit
    inline eval fn is_digit(self, c: char32) -> bool {
        return hex_lut[static_cast::<u8>(c) & 0xFF] != 0xFF;
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
