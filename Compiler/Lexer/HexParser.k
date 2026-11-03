/// --- The Kairo Project ---------------------------- Lexer/HexParser.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// \brief value of a hex digit byte: '0'-'9' -> 0-9, 'A'-'F' and 'a'-'f' ->
///        10-15, 0xFF for anything else (an invalid digit).
///
/// \details was a 256-entry `static constexpr` table built by a C++ lambda.
///          It is indexed by the low byte of the code point, so callers keep
///          passing `static_cast::<u8>(c)` exactly as they indexed the table.
eval fn hex_digit_lut(b: u8) -> u8 {
    if (b >= 48) && (b <= 57)  { return static_cast::<u8>(b - 48); }       // '0'-'9'
    if (b >= 65) && (b <= 70)  { return static_cast::<u8>(b - 65 + 10); }  // 'A'-'F'
    if (b >= 97) && (b <= 102) { return static_cast::<u8>(b - 97 + 10); }  // 'a'-'f'
    return 0xFF;
}

/// \brief incremental hexadecimal digit parser
/// \details used for escape sequence decoding (\x, \u, \U)
class HexParser {
    var value:  usize = 0;
    var digits: usize = 0;

    /// \brief appends a hex digit
    /// \param c hex digit character
    /// \requires is_digit(c) == true
    inline eval fn push_back(self, c: char32) {
        const v: u8 = hex_digit_lut(static_cast::<u8>(c));
        self.value = (self.value << 4) | static_cast::<usize>(v);
        ++(self.digits);
    }

    /// \brief checks whether character is a valid hex digit
    /// \param c input character
    /// \returns true if valid hex digit
    inline eval fn is_digit(self, c: char32) -> bool {
        return hex_digit_lut(static_cast::<u8>(c)) != 0xFF;
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
