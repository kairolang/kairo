/// --- The Kairo Project ---------------------- Resolution/ModulePath.k --- ///
///
///   ModulePath: a module path as a list of identifier tokens.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"
ffi "c++" import "algorithm"

import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Token::IdentifierToken::IdentifierToken

pub class ModulePath { // 256-bit class (32 bytes - max)
    pub var segments: cxx::std::vector<IdentifierToken> ///< each segment is an identifier token this does not include the "::" tokens

    fn as_string(const self, sym_table: unsafe *PreprocessorSymbolTable) -> string {
        if self.segments.size() == 0 {
            return "<global>"
        }

        var result: string = ""
        var back           = self.segments.back()

        result.reserve(self.segments.size() * 12)

        for seg in self.segments {
            result += seg.as_string(sym_table) + (if (seg != back) => "::" else => "")
        }

        return result
    }

    fn op < (const self, other: ModulePath) -> bool {
        var n = cxx::std::min(self.segments.size(), other.segments.size())

        for i in (0 as usize)..(n) {
            if self.segments[i].name != other.segments[i].name {
                return self.segments[i].name < other.segments[i].name
            }
        }

        return self.segments.size() < other.segments.size()
    }
}
