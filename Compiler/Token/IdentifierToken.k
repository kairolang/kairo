/// --- The Kairo Project ---------------------- Token/IdentifierToken.k --- ///
///
///   IdentifierToken: an identifier's SymbolID paired with its source Token.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Preprocessor::PreprocessorSymbolTable::{
    PreprocessorSymbolTable,
    SymbolID,
}
import Token::Token::Token

pub class IdentifierToken {
    pub var name:  SymbolID
    pub var token: unsafe *Token ///< pointer to the original identifier token

    fn IdentifierToken(self, name: SymbolID, token: unsafe *Token) {
        self.name  = name
        self.token = token
    }

    pub fn IdentifierToken(self) = default

    pub fn as_string(const self, sym_table: unsafe *PreprocessorSymbolTable) -> string {
        var unsafe *name_str_ptr = sym_table->resolve(self.name)
        var        name_str      = if (name_str_ptr == &null) => "<invalid>" else => *name_str_ptr
        return f"IdentifierToken(name: '{name_str}', token: {self.token})"
    }

    fn op == (const self, other: IdentifierToken) -> bool {
        return self.token == other.token
    }

    pub fn op != (const self, other: IdentifierToken) -> bool {
        return !(self == other)
    }

    fn op == (const self, other: SymbolID) -> bool {
        return self.name == other
    }

    fn op != (const self, other: SymbolID) -> bool {
        return !(self == other)
    }

    fn op < (const self, other: IdentifierToken) -> bool {
        return self.name < other.name
    }

    fn op > (const self, other: IdentifierToken) -> bool {
        return self.name > other.name
    }
}
