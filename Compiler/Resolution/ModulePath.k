/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Preprocessor::PreprocessorSymbolTable::*;
import Token::IdentifierToken::*;

class ModulePath { // 256-bit class (32 bytes - max)
    pub var segments: vec::<IdentifierToken>; ///< each segment is an identifier token this does not include the "::" tokens

    const fn as_string(self, sym_table: *PreprocessorSymbolTable) -> string {
        if self.segments.size() == 0 {
            return "<global>";
        }

        var result: string = "";
        var back = self.segments.back();

        result.reserve((segments.size()) * 12);

        for seg in self.segments {
            result += seg.as_string(sym_table) + ("::" if (seg != back) else "");
        }

        return result;
    }

    const fn op < (self, other: ModulePath) -> bool {
        var n = __inline_cpp("(libcxx::min)(this->segments.size(), other.segments.size())");

        for i in usize(0)..usize(n) {
            if self.segments[i].name != other.segments[i].name {
                return self.segments[i].name < other.segments[i].name;
            }
        }

        return self.segments.size() < other.segments.size();
    }
}