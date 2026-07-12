/// --- The Kairo Project ---------------------------- Macro/Parameter.k --- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::IdentifierToken::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Token::TokenSpan::*;

class MacroParameter {
    enum VariadicType derives u8 {
        None,    ///< not variadic
        Named,   ///< named variadic (e.g., =...rest)
        Unnamed, ///< unnamed variadic (e.g., ...rest)
    }

    pub var name:          IdentifierToken;
    pub var has_default:   bool         = false;
    pub var is_variadic:   VariadicType = VariadicType::None;
    pub var default_value: TokenSpan;

    const fn as_string(self, sym_table: *PreprocessorSymbolTable) -> string {
        var repr = f"MacroParameter(name: '{self.name.as_string(sym_table)}\x27";
        switch self.is_variadic {
            case VariadicType::Named {
                repr += ", is_variadic: named";
            } case VariadicType::Unnamed {
                repr += ", is_variadic: unnamed";
            } case VariadicType::None {
                repr += ", is_variadic: false";
            }
        }

        if self.has_default {
            repr += f", has_default: true, default_value: {self.default_value}";
        } else {
            repr += ", has_default: false, default_value: null";
        }

        return repr + ")";
    }
}