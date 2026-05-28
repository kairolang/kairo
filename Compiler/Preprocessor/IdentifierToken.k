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

import Lexer::Token::*;
import Preprocessor::PreprocessorSymbolTable::*;

type SymbolID = u32;;

class IdentifierToken {
    pub var name:  SymbolID;
    pub var token: obs::<Token>; ///< pointer to the original identifier token

    fn IdentifierToken(self, name: SymbolID, token: *Token) {
        self.name = name;
        self.token = token;
    }

    default fn IdentifierToken(self);

    const fn as_string(self, sym_table: *PreprocessorSymbolTable) -> string {
        var name_str_ptr = sym_table->resolve(self.name);
        var name_str = "<invalid>" if (name_str_ptr == &null) else *name_str_ptr;
        return f"IdentifierToken(name: '{name_str}', token: {self.token})";
    }

    const fn op == (self, other: IdentifierToken) -> bool {
        return (self.token) == (other.token);
    }

    const fn op != (self, other: IdentifierToken) -> bool {
        return !(self == other);
    }

    const fn op == (self, other: SymbolID) -> bool {
        return self.name == other;
    }

    const fn op != (self, other: SymbolID) -> bool {
        return !(self == other);
    }

    const fn op < (self, other: IdentifierToken) -> bool {
        return self.name < other.name;
    }

    const fn op > (self, other: IdentifierToken) -> bool {
        return self.name > other.name;
    }
}